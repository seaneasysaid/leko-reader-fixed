--[[--
段评配图下载（子进程，UI 线程零阻塞）。

移植自 fanqie 主程序的 fetch_review_pic：图片是几十 KB 的二进制，同步下载
会在电纸书上卡住翻页；放到子进程里跑，父进程只等一个 ok 信封。

图片字节**不经过** SubprocessPayload（那是给纯数据表用的 JSON 通道）：子进程
直接把图片写到目标路径，只回 { ok=true/false, bytes=… }。父进程用 gen 判断
弹窗是否还在，widget 层负责串行调度与去重（见 review_popup/widget.lua）。

用 ProcessBudget 的 background 道排队，避免和正文/段评前台任务抢内存。
]]--

local socket = require("socket")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local Http = require("Leko/Http")
local MemoryGuard = require("Leko/MemoryGuard")
local ProcessBudget = require("Leko/ProcessBudget")
local Storage = require("Leko/Storage")
local SubprocessPayload = require("Leko/SubprocessPayload")

local AsyncImageFetch = {
    poll_interval = 0.15,
    reap_interval = 0.25,
    hard_timeout = 30,
    queue_timeout = 12,
    -- 单张上限 8MB；超过当异常处理（段评图一般几十 KB）。
    max_image_bytes = 8 * 1024 * 1024,
}

local workers = {}

local function releaseBudget(worker)
    if not worker or not worker.budget_ticket then return end
    local ticket = worker.budget_ticket
    worker.budget_ticket = nil
    ProcessBudget:release(ticket)
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

-- 子进程里跑：下载 → 写目标文件 → 返回状态。
local function downloadJob(job)
    -- 必须走 request(options)：get(url, headers) 的第二个参数是 headers 表，
    -- 把 timeout / max_bytes / decompress 混进去会当 header 发出且选项失效。
    local response, err = Http:request({
        url = job.url,
        method = "GET",
        timeout = 12,
        maxtime = 25,
        retries = 0,
        decompress = false,
        max_bytes = job.max_bytes,
        accept = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
    })
    if not response then return { ok = false, error = tostring(err or "图片下载失败") } end
    local body = response.body
    if type(body) ~= "string" or #body == 0 then
        return { ok = false, error = "图片返回为空" }
    end
    -- 错误页 / 半截图一旦写进缓存就再也不会重下（file_exists 只看大小）。
    -- 落盘前用文件头确认是图片，不合格就当本次失败，并清掉可能存在的旧坏文件。
    local ok_pics, ReviewPics = pcall(require, "Leko/ReviewPics")
    if ok_pics and type(ReviewPics) == "table"
        and not ReviewPics.is_image_bytes(body) then
        pcall(os.remove, job.path)
        return { ok = false, error = "图片内容无效" }
    end
    local f = io.open(job.path, "wb")
    if not f then return { ok = false, error = "无法写入图片缓存" } end
    local wrote, write_err = f:write(body)
    local ok_close, close_err = f:close()
    if not wrote or not ok_close then
        -- 半截文件必须删掉，否则 file_exists 会把它当成有效缓存永不重下。
        pcall(os.remove, job.path)
        return { ok = false, error = tostring(write_err or close_err or "写入图片失败") }
    end
    return { ok = true, bytes = #body }
end

local function deliver(worker, ok, payload, err)
    local callback = worker.callback
    worker.callback = nil
    workers[worker] = nil
    releaseBudget(worker)
    if worker.cancelled or type(callback) ~= "function" then return end
    local function run() pcall(callback, ok, payload, err) end
    if type(UIManager.nextTick) == "function" then UIManager:nextTick(run)
    else UIManager:scheduleIn(0, run) end
end

function AsyncImageFetch:_finish(worker)
    if not worker or worker.finished then return end
    worker.finished = true
    local fd, path = worker.result_fd, worker.payload_path
    worker.result_fd, worker.payload_path = nil, nil
    local payload, read_err = SubprocessPayload:read(fd, path, { max_bytes = 64 * 1024 })
    if type(payload) ~= "table" then
        return deliver(worker, false, nil, tostring(read_err or "图片下载没有返回结果"))
    end
    if payload.ok ~= true then
        return deliver(worker, false, nil, tostring(payload.error or "图片下载失败"))
    end
    return deliver(worker, true, payload, nil)
end

function AsyncImageFetch:_poll(worker)
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
            deliver(worker, false, nil, "图片下载超时")
        else
            UIManager:scheduleIn(self.reap_interval, reap)
        end
    end
    UIManager:scheduleIn(self.reap_interval, reap)
end

--- 下载单张图片到 path。callback(ok, payload, err)。
function AsyncImageFetch:fetch(url, path, callback)
    if type(url) ~= "string" or url == "" or type(path) ~= "string" or path == "" then
        if callback then UIManager:nextTick(function() callback(false, nil, "图片地址无效") end) end
        return nil
    end
    local worker = {
        callback = callback,
        cancelled = false,
        finished = false,
        requested_at = socket.gettime(),
        timeout_seconds = self.hard_timeout,
    }
    local function spawn(ticket)
        worker.budget_ticket = ticket
        if worker.cancelled then
            worker.finished = true
            ProcessBudget:release(ticket)
            return
        end
        local payload_path = SubprocessPayload:newPath("img-fetch",
            type(Storage.getCacheDir) == "function" and Storage:getCacheDir("tmp") or "/tmp")
        local job = { url = url, path = path, max_bytes = self.max_image_bytes }
        pcall(MemoryGuard.prepareForFork, MemoryGuard)
        local pid, result_fd_or_err = ffiutil.runInSubProcess(function(_, write_fd)
            SubprocessPayload:write(write_fd, payload_path, downloadJob(job),
                { max_bytes = 64 * 1024 })
        end, true)
        if not pid then
            SubprocessPayload:cleanup(payload_path)
            worker.finished = true
            ProcessBudget:release(ticket)
            worker.budget_ticket = nil
            deliver(worker, false, nil, tostring(result_fd_or_err or "无法启动图片下载"))
            return
        end
        worker.pid = pid
        worker.result_fd = result_fd_or_err
        worker.payload_path = payload_path
        worker.started_at = socket.gettime()
        UIManager:scheduleIn(self.poll_interval, function() self:_poll(worker) end)
    end
    workers[worker] = true
    local ticket = ProcessBudget:request{
        owner = worker,
        label = "段评配图",
        lane = "background",
        priority = 1,
        on_start = spawn,
        on_error = function(err)
            worker.finished = true
            deliver(worker, false, nil, tostring(err))
        end,
    }
    if ticket and worker.finished == false and not worker.pid then
        -- 排队中：内存紧张时 background 道可能长时间拿不到额度。到点仍未启动
        -- 就主动撤单并回调失败，否则 widget 的串行队列会永远卡在这一张图上。
        UIManager:scheduleIn(self.queue_timeout, function()
            if worker.finished or worker.pid then return end
            worker.finished = true
            pcall(ProcessBudget.cancel, ProcessBudget, ticket)
            worker.budget_ticket = nil
            deliver(worker, false, nil, "图片下载排队超时")
        end)
    end
    return worker
end

function AsyncImageFetch:cancelAll()
    for worker in pairs(workers) do
        worker.cancelled = true
        if worker.pid and not worker.finished then pcall(ffiutil.terminateSubProcess, worker.pid) end
        closePipe(worker)
        releaseBudget(worker)
    end
    workers = {}
end

return AsyncImageFetch
