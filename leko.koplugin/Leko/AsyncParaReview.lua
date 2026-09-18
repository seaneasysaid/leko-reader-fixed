--[[--
段评后台取数：把会阻塞的 HTTP 请求挪到子进程。

段评的取数链路是同步 HTTP（书山 `/para` 与 `/idea_comment` 每页稳定 4–5 秒，
首屏可能连拉两页）。留在 UI 线程里意味着这几秒内整台机器不响应任何输入 ——
换章时自动补计数、点气泡拉正文，都是这样卡住读者的。番茄插件那套做法
（横幅「正在获取段评…」+ 请求丢子进程）已经验证可行，这里照搬思路。

与前台书籍任务（Leko/AsyncBookOperation）共用同一套子进程基建：

  * 结果经 Leko/SubprocessPayload 回传 —— 小结果走管道，大结果落临时文件并
    只把路径过管道，不会因为管道写满而父子互相等死（上百条评论正文很容易
    超过管道缓冲）；
  * 并发交给 Leko/ProcessBudget —— Kindle 上多个子进程同时 fork 会把内存
    峰值推上去，严重时会把框架本身顶重启，所以段评也不能自开一条路，
    只能排队。段评的正文请求走 foreground 道（读者刚刚点的），自动补计数
    走 background 道：前者一启动就会把后者停掉，省下一台镜像的排队时间。

和 AsyncBookOperation 的差别：那个协议的出口绑死了「书籍操作」（要
BookOperationSpec、要 Storage:loadBook 回填 book），段评要的只是一个数据表，
所以这里只做 fork + 轮询 + 回传，没有引入第二套书籍语义。

缓存键与镜像记忆的一致性：子进程是 fork 出来的，拿到的是父进程那一刻的
book / source 副本，所以父子两边算出来的缓存键、镜像顺序完全相同 —— 不会
出现父进程写一份、子进程读另一份。反向的偏差只有一处：子进程里选中的镜像
记在它自己的副本上（Shushan:_rememberHost 还会落盘），父进程看不到，所以
子进程把实际使用的镜像一并回传，由调用方同步回自己的 source
（见 AsyncParaReview.rememberSourceHost）。
]]--

local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local MemoryGuard = require("Leko/MemoryGuard")
local ParaComments = require("Leko/ParaComments")
local ProcessBudget = require("Leko/ProcessBudget")
local Shushan = require("Leko/Shushan")
local Storage = require("Leko/Storage")
local SubprocessPayload = require("Leko/SubprocessPayload")
local logger = require("logger")

local AsyncParaReview = {
    -- 子进程自己跑，轮询间隔不必太细；0.15 秒一次足够及时，也不至于空转。
    poll_interval = 0.15,
    reap_interval = 0.25,
    -- 一次任务的兜底超时。单页超时由 ParaComments.TIMEOUT 管，这里更大的
    -- 作用是不让「镜像挂住不回」把子进程永远留在内存里。首屏两页 + 可能的
    -- 镜像轮换，给足余量；读者随时可以取消。
    hard_timeout = 75,
    -- 排队等 ProcessBudget 放行的上限。等这么久说明前面有前台书籍任务在跑，
    -- 这时报「稍后再试」比让读者盯着转圈强。
    queue_timeout = 12,
    result_payload_limit = 1024 * 1024,
}

-- 同一类任务只留一个在飞（见 start）。
local workers = { counts = nil, comments = nil }

local LANES = { counts = "background", comments = "foreground" }
local LABELS = { counts = "段评计数", comments = "段评正文" }

--[[--
计数表是 `{ [pid] = count }`，pid 从 0 起。

直接把它交给 rapidjson 会被当成数组编出去 —— 键 0 会被丢掉、其余整体前移
一位，读者看到的气泡就挂到别的段上去了。所以跨越子进程边界时先摊平成
`{ {pid=, count=} }` 列表（数组，JSON 一定编得对），父进程再拼回映射表。

条目很少（一章里带评论的段落），多这一步的代价可以忽略。
]]--
local function countsToPairs(counts)
    local rows = {}
    for pid, count in pairs(counts or {}) do
        pid = tonumber(pid)
        count = tonumber(count)
        if pid and count and count > 0 then
            rows[#rows + 1] = { pid = pid, count = count }
        end
    end
    -- 排一下序：结果稳定，出问题时日志 / 缓存里看到的东西每次都长一样。
    table.sort(rows, function(left, right) return left.pid < right.pid end)
    return rows
end

local function pairsToCounts(rows)
    local counts = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if type(row) == "table" then
            local pid = tonumber(row.pid)
            local count = tonumber(row.count)
            if pid and pid >= 0 and count and count > 0 then counts[pid] = count end
        end
    end
    return counts
end

--[[--
子进程要干的活。只读参数、只回纯数据表。

book / source 是 fork 下来的父进程副本，因此这里调 ParaComments 和父进程直接
调它得到的结果（含缓存键、镜像顺序）完全一致。
]]--
local function runJob(job)
    local source = job.source
    if type(source) ~= "table" then return { ok = false, error = "没有找到可用的书源" } end
    local book = job.book
    if type(book) ~= "table" then return { ok = false, error = "没有正在阅读的书籍" } end

    if job.kind == "counts" then
        local counts, err = ParaComments.ensureCounts(book, job.chapter_index, source,
            -- paragraphs 只有七猫用得上（它按段落内容指纹定位，见 ParaComments）。
            -- 它是 fork 下来的内存副本，不经过序列化，所以直接带过来即可。
            { force = job.force, paragraphs = job.paragraphs })
        if type(counts) ~= "table" then
            return { ok = false, error = tostring(err or "段评计数获取失败") }
        end
        return {
            ok = true,
            counts = countsToPairs(counts),
            host = ParaComments.hostKey(source),
        }
    end

    local list, para_text, err, page = ParaComments.fetchComments(book, job.chapter_index, source,
        job.pid, { cursor = job.cursor, force = job.force, paragraphs = job.paragraphs })
    if type(list) ~= "table" then
        return { ok = false, error = tostring(err or "段评获取失败") }
    end
    return {
        ok = true,
        list = list,
        para_text = tostring(para_text or ""),
        page = page,
        host = ParaComments.hostKey(source),
    }
end

local function closePipe(worker)
    if not worker then return end
    if worker.result_fd then
        local fd = worker.result_fd
        worker.result_fd = nil
        pcall(ffiutil.readAllFromFD, fd)
    end
    SubprocessPayload:cleanup(worker.payload_path)
    worker.payload_path = nil
end

local function releaseBudget(worker)
    if not worker or not worker.budget_ticket then return end
    local ticket = worker.budget_ticket
    worker.budget_ticket = nil
    ProcessBudget:release(ticket)
end

--[[--
把结果交回调用方。

一律绕到 UIManager 的下一拍再回调：这里可能是从子进程回收路径进来的
（UIManager 正在跑自己的定时器），直接回调会让调用方在 UIManager 内部
开/关窗口，晚一拍最稳。回调前先把并发额度还掉，回调里再发起新请求
才不会被自己卡住。
]]--
local function deliver(worker, ok, payload, err)
    local callback = worker.callback
    worker.callback = nil
    -- 段落文本只有子进程跑任务那一下要用（七猫靠它定位段落），到这里已经结束：
    -- 顺手松开，别让几百段正文一直挂在 worker 上。
    worker.paragraphs = nil
    releaseBudget(worker)
    if worker.cancelled or type(callback) ~= "function" then return end
    local function run() pcall(callback, ok, payload, err) end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

function AsyncParaReview:_finish(worker)
    if not worker or worker.finished then return end
    worker.finished = true
    local fd, path = worker.result_fd, worker.payload_path
    worker.result_fd, worker.payload_path = nil, nil
    local payload, read_err = SubprocessPayload:read(fd, path,
        { max_bytes = self.result_payload_limit })
    if type(payload) ~= "table" then
        return deliver(worker, false, nil, tostring(read_err or "段评请求没有返回结果"))
    end
    if payload.ok ~= true then
        return deliver(worker, false, nil, tostring(payload.error or "段评请求失败"))
    end
    if worker.kind == "counts" then
        payload.counts_map = pairsToCounts(payload.counts)
    end
    return deliver(worker, true, payload, nil)
end

function AsyncParaReview:_poll(worker)
    if not worker or worker.finished then return end
    if ffiutil.isSubProcessDone(worker.pid) then return self:_finish(worker) end

    local elapsed = socket.gettime() - worker.started_at
    if elapsed < worker.timeout_seconds then
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
        return
    end

    worker.finished = true
    pcall(ffiutil.terminateSubProcess, worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closePipe(worker)
            deliver(worker, false, nil, "段评请求超时了，请稍后再试")
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

function AsyncParaReview:_watchQueue(worker)
    if not worker or worker.finished or worker.cancelled or not worker.pending then return end
    local elapsed = socket.gettime() - (worker.requested_at or socket.gettime())
    if elapsed < worker.queue_timeout_seconds then
        UIManager:scheduleIn(self.poll_interval, function() self:_watchQueue(worker) end)
        return
    end
    worker.finished = true
    worker.pending = false
    --[[--
    排队等太久了：结果已经用不上，但**额度必须还掉**。

    ProcessBudget:request 返回的那张票在排队期间只存在于它的队列里
    （spawn 还没跑，worker.budget_ticket 还是 nil）。不退票的话，这张票将来
    一定会被派发到 —— 那时 spawn 会真的 fork 一个子进程，而 _poll 一看
    worker.finished 就立刻返回、永远走不到 releaseBudget，于是这条 lane 被
    一张不会释放的票堵死：之后所有自动补计数、乃至前台书籍任务都排不上队。

    先 deliver 再置 cancelled：deliver 会因为 cancelled 直接吞掉回调，
    而 cancelled 又让「万一已经派发到」的那一次 spawn 立刻把票还回去。
    ]]--
    if worker.queue_ticket then
        ProcessBudget:cancel(worker.queue_ticket)
        worker.queue_ticket = nil
    end
    deliver(worker, false, nil, "阅读器正忙，段评稍后再试")
    worker.cancelled = true
end

--[[--
开始一个段评请求。

kind       "counts"（本章评论计数）| "comments"（某一段的评论正文）
job.book   当前 book 表（fork 后子进程会拿到同一份副本）
job.source 当前书源（同上）
job.chapter_index / job.pid / job.cursor / job.force
job.paragraphs
           本章段落文本（model.paragraphs）。只有七猫要用：它按段落内容指纹
           定位，子进程得拿同一份段落才能算出同样的指纹。fork 直接复制内存，
           不经过序列化，所以带它没有代价。
callback   function(ok, payload, err)。payload.counts_map（counts）或
           payload.list / payload.para_text / payload.page（comments）。

同一类任务重复发起时，前一个会被取消（superseded）。返回 worker 句柄。
]]--
function AsyncParaReview:start(kind, job, callback)
    if kind ~= "counts" and kind ~= "comments" then
        return nil, "未知的段评任务类型"
    end
    job = job or {}
    -- 段评弹窗一次只展示一段；重复请求没有意义，而且两个子进程同时改同一份
    -- 磁盘缓存会互相覆盖（缓存是读-改-写）。
    self:cancel(kind, "superseded")

    local worker = {
        kind = kind,
        book = job.book,
        source = job.source,
        chapter_index = tonumber(job.chapter_index) or 0,
        pid = tonumber(job.pid),
        cursor = tonumber(job.cursor),
        force = job.force == true,
        -- 七猫定位段落要用（见 runJob）。任务结束时会在 deliver 里清掉，
        -- 免得几百段正文一直挂在 worker 上。
        paragraphs = job.paragraphs,
        callback = callback,
        on_cancel = job.on_cancel,
        cancelled = false,
        finished = false,
        pending = true,
        timeout_seconds = math.max(10, tonumber(job.timeout_seconds) or self.hard_timeout),
        queue_timeout_seconds = math.max(3, tonumber(job.queue_timeout) or self.queue_timeout),
        requested_at = socket.gettime(),
    }

    local function spawn(ticket)
        worker.pending = false
        worker.queue_ticket = nil
        worker.budget_ticket = ticket
        if worker.cancelled then
            worker.finished = true
            releaseBudget(worker)
            return
        end
        local payload_path = SubprocessPayload:newPath("para-review-" .. kind,
            type(Storage.getCacheDir) == "function" and Storage:getCacheDir("tmp") or "/tmp")
        local job = {
            kind = kind,
            book = worker.book,
            source = worker.source,
            chapter_index = worker.chapter_index,
            pid = worker.pid,
            cursor = worker.cursor,
            force = worker.force,
            paragraphs = worker.paragraphs,
        }
        -- fork 前先收一次垃圾：子进程只会 COW 复制脏页，heap 越干净峰值越低。
        -- Kindle 上「父进程 + 子进程」同时占内存正是框架重启的常见触发条件。
        pcall(MemoryGuard.prepareForFork, MemoryGuard)
        local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
            SubprocessPayload:write(write_fd, payload_path, runJob(job),
                { max_bytes = AsyncParaReview.result_payload_limit })
        end, true)
        if not pid then
            SubprocessPayload:cleanup(payload_path)
            worker.finished = true
            releaseBudget(worker)
            deliver(worker, false, nil, tostring(result_fd_or_err or "无法启动段评后台任务"))
            return
        end
        worker.pid = pid
        worker.result_fd = result_fd_or_err
        worker.payload_path = payload_path
        worker.started_at = socket.gettime()
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end

    worker.cancel = function(reason) return AsyncParaReview:cancel(kind, reason) end
    workers[kind] = worker

    -- 段评正文是读者刚点出来的，走前台道（会顺带停掉自动补计数那个后台子进程，
    -- 免得两台镜像同时被占着排队）；自动补计数只是锦上添花，走后台道，
    -- 前台书籍任务要跑时让路。
    local ticket = ProcessBudget:request{
        owner = worker,
        label = LABELS[kind],
        lane = LANES[kind],
        priority = (kind == "comments") and 85 or 2,
        on_start = spawn,
        on_preempt = function() self:cancel(kind, "preempted") end,
        on_error = function(err)
            worker.pending = false
            worker.finished = true
            deliver(worker, false, nil, tostring(err))
        end,
    }
    -- 票要留着：排队超时（_watchQueue）得靠它把自己从队列里摘出去。
    -- 额度够时 request 会**同步**把 spawn 跑掉，那时 pending 已经是 false，
    -- 这张票的使命也就结束了 —— 之后由 worker.budget_ticket 记账。
    if worker.pending then
        worker.queue_ticket = ticket
        UIManager:scheduleIn(self.poll_interval, function() self:_watchQueue(worker) end)
    end
    return worker
end

--- 取消某一类段评请求。返回是否确实取消掉了东西。
function AsyncParaReview:cancel(kind, reason)
    local worker = workers[kind]
    if not worker then return false end
    workers[kind] = nil
    worker.cancelled = true
    if type(worker.on_cancel) == "function" then pcall(worker.on_cancel, reason or "cancelled") end

    -- 还在排队：把票退掉即可，没有子进程要收。
    if worker.pending then
        worker.pending = false
        worker.finished = true
        -- 排队期间 worker.budget_ticket 还是 nil，票只在 ProcessBudget 的队列里
        -- （见 start 里的 queue_ticket）。不退掉它，一张已作废的**前台**票会让
        -- ProcessBudget:_hasQueuedForeground() 一直为真，把自动补计数等后台活
        -- 全挡在门外，直到这张票被派发才恢复。
        local ticket = worker.queue_ticket or worker.budget_ticket
        if ticket then ProcessBudget:cancel(ticket) end
        worker.queue_ticket = nil
        worker.budget_ticket = nil
        worker.callback = nil
        return true
    end

    if worker.finished or not worker.pid then
        worker.finished = true
        releaseBudget(worker)
        worker.callback = nil
        return true
    end

    pcall(ffiutil.terminateSubProcess, worker.pid)
    local function reap()
        if ffiutil.isSubProcessDone(worker.pid) then
            closePipe(worker)
            releaseBudget(worker)
            worker.callback = nil
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
    return true
end

--- 有没有某一类请求在飞（调用方用来避免无谓地再发一次）。
function AsyncParaReview:isRunning(kind)
    local worker = workers[kind]
    return worker ~= nil and not worker.finished
end

--[[--
把子进程实际选中的镜像同步回父进程的 source。

子进程里 Shushan:_rememberHost 选中的镜像只写在它自己的副本上（外加落盘），
父进程那份还停在旧镜像。不同步会有两处代价：下一次 hostOrder 又把旧镜像
先试一遍，白等一次注定失败的请求 —— 正是「获取段评很慢」的一部分；
ReaderView 还用 hostKey 判断「这批计数是不是当前镜像取的」，不同步就永远
判成过期，每翻一章都重新拉一次。

写的是 login_info 里的内部键，与 _rememberHost 落盘的内容一致，重复写同一
个值没有副作用（调用前会比一下）。
]]--
function AsyncParaReview.rememberSourceHost(source, host)
    if type(source) ~= "table" then return false end
    host = tostring(host or ""):gsub("/+$", "")
    if host == "" then return false end
    if ParaComments.host(source) == host then return false end
    local ok = pcall(function() Shushan:setLoginInfo(source, { [Shushan.KEY_HOST] = host }) end)
    if not ok then
        logger.warn("Leko para review: cannot sync mirror back to parent", host)
    end
    return ok
end

--- 换书 / 关闭阅读器时收摊：取消所有在飞的请求。
function AsyncParaReview:release()
    self:cancel("counts", "released")
    self:cancel("comments", "released")
end

return AsyncParaReview
