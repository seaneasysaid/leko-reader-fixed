--[[--
段评（段落评论）数据层 —— 原生书山驱动版。

支持三个平台的章节：

  番茄小说  chapter.source 含「番茄」，参数 book_id=bookid & item_id=itemid
  QQ阅读    chapter.source 含「QQ」，参数 book_id=bookid & chapter_id=chapterid
  七猫小说  chapter.source 含「七猫」，参数 book_id=bookid & item_id=itemid
            —— 七猫的 item_id / content_md5 不在章节 url 载荷的固定字段里
            （那不是能随便加的：载荷字段集一改，已落盘目录就会解包错位），
            但载荷里的 curl 保留了目录给的原始章节 url，从它解析。

接口（都由书山聚合后端提供）：

  计数（气泡）  GET {host}/para?source=<fq|qm|qq>&book_id=<bid>&chapter_id=<cid>
                七猫另需 &content_md5=<目录给的 content md5>
                -> {data:{total, list:[{paragraph_id, comment_count, ...}]}}

  评论正文      番茄 GET {host}/idea_comment?api=1&book_id=&item_id=&para=&cursor=0&count=&sort=1
                -> {data:{para_src_content:"<原文段落>", data_list:[{comment:{...}}]}}
                QQ   GET {host}/qq_comment?ajax=1&bid=&cid=&para=
                -> {comments:[{nick, replyContent, agree, createTime, ...}],
                    hasNext, nextCursor, currentCount}
                七猫 GET {host}/paras/proxy_qmidea?action=paragraph_first
                         &book_id=&item_id=&paragraph_id=<段落内容指纹>
                -> {data:{hot_zone:{comment_list,comment_count},
                          time_zone:{comment_list,comment_count,next_id}}}

`paragraph_id` 的含义分两种：

  * 番茄 / QQ 是**正文非空段落的 0 基序号**，与 `Util.splitParagraphs` 保留下来的
    段落一一对应（第 pid 段 = model.paragraphs[pid + 1]）；
  * 七猫是**段落文本的内容指纹**（md5(去首尾空白的段落原文)[:8]），后端不认段号。
    所以七猫要把本地段落先换算成指纹，才能把计数挂回正确的段上
    （见 ParaComments.qmFingerprint / qmCountsByParagraph）。

番茄的 `para_src_content` / QQ 的 `lineContent` 可用来校验这个对齐关系。

请求一律走 Leko/Shushan 的原生通道：镜像轮换、凭据刷新、设备头都由它统一处理，
段评与正文因此天然落在同一台镜像上。

本模块只负责取数与解析：不碰 UI，不在 Paginator 里发网络请求。计数结果放在内存
表里，供分页器 / ReaderView 做纯本地查询；新增章节时才发生一次网络往返，且带磁盘
缓存。
]]--

local Digest = require("Leko/Digest")
local Shushan = require("Leko/Shushan")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")
local logger = require("logger")

local ParaComments = {}

-- 计数变化很慢：一小时内重复打开同一章不再请求。
ParaComments.COUNTS_TTL = 60 * 60
-- 评论正文 TTL 稍长，翻回同一段不该再打一次后端。
ParaComments.COMMENTS_TTL = 6 * 60 * 60
-- 单次请求取多少条评论。
--
-- 实测（2026-09-18，书山 /idea_comment）：服务端只稳定接受 20 ——
-- count=30 / 40 一律回 `{"error":"获取评论失败"}`，count=50 三成概率挂住
-- 20 秒以上（同一台镜像时好时坏），只有 count=20 是 3/3 稳定（2–4 秒）。
-- 所以「看到更多」不能靠调大这一页，只能靠 cursor 续拉。
ParaComments.PAGE_SIZE = 20

-- 首次打开时一次连拉几页。
--
-- 一页只有 20 条，读者点开弹窗却只看到 20 条就是这个问题。首屏连拉两页能
-- 一次给出 40 条；续拉走单页 —— 那个按钮的语义是「再来一批」，一次等两页
-- 没有意义。
--
-- 代价说清楚：服务端每页稳定 4–5 秒，所以首屏要等约 9 秒。这个等待必须放在
-- 子进程里（见 Leko/AsyncParaReview），否则整台机器会僵住约 9 秒。
ParaComments.FIRST_OPEN_PAGES = 2
-- 段评是阅读路径上的附加请求，宁可失败也不要长时间卡住翻页。
ParaComments.TIMEOUT = 15
ParaComments.CACHE_KIND = "para_review"

local counts_cache = {}

-- 平台表：match 命中 chapter.source，字段名按各家协议取。
--
-- ids_from_curl 的平台，其 item_id / content_md5 不在章节 url 载荷的固定字段里
-- （七猫的章节 url 形如 `book_id=219542&item_id=16385010360001&content_md5=9d0c…`，
-- 而载荷只装 CHAPTER_FIELDS，七猫的 item_id / content_md5 都不在其中），
-- 要从载荷里的 curl（目录给的原始章节 url）解析。
local PLATFORMS = {
    {
        code = "fq", label = "番茄",
        match = "番茄",
        book_field = "bookid", chapter_field = "itemid",
    },
    {
        code = "qm", label = "七猫",
        match = "七猫",
        book_field = "bookid", chapter_field = "itemid",
        ids_from_curl = true,
    },
    {
        code = "qq", label = "QQ阅读",
        match = "QQ",
        book_field = "bookid", chapter_field = "chapterid",
    },
}

local function text(value)
    return tostring(value == nil and "" or value)
end

local function trim(value)
    return Util.trim(text(value))
end

--[[--
把协议里的数字参数写成十进制整数。

不能图省事用 tostring：`tonumber(服务端 JSON 里的数字)` 得到的是浮点数，
`tostring` 在部分实现下会给出 "20.0"，而服务端不接受带小数点的
`cursor=` / `para=`（那会被判成另一段或直接报错）。段号 pid 是从分页器一路
算出来的，同样可能是浮点数，所以统一从这里过一道。
]]--
local function intText(value)
    local number = tonumber(value)
    if not number then return "0" end
    return string.format("%d", math.floor(number))
end

--[[--
从目录给的原始章节 url 里取一个 query 参数。

七猫的章节 url 是 `book_id=…&item_id=…&content_md5=…` 这种裸 query（没有 `?`），
所以 `?` 与 `&` 都当作可选分隔符。取不到就回空串，由调用方决定要不要报错。
]]--
local function queryValue(url, name)
    if type(url) ~= "string" or url == "" then return "" end
    local value = url:match("[?&]?" .. name .. "=([^&]+)")
    if value == nil then return "" end
    return trim(value)
end

--[[--
章节的平台字段（source / bookid / itemid / chapterid）。

目录落盘后只剩 `{title, url}`：平台字段是打包在章节 url 的 base64 载荷里的
（Shushan 的 CHAPTER_FIELDS / unpack_fields），所以「刚搜出来还在内存里」和
「重启阅读器后从 toc.lua 读回来」这两种章节长得并不一样 —— 只看 chapter.source
会让第二种情况整体判成「不支持段评」，读者会以为这本书没有段评。

于是统一在一处取字段：有内存字段就用内存的，没有就从 url 载荷解。解出来的表
按 url 记住（章节表本身是短命的，当不了缓存键），并在换书时清掉。
]]--
local platform_fields, platform_field_count = {}, 0

local function chapterFields(chapter)
    if type(chapter) ~= "table" then return nil end
    if trim(chapter.source) ~= "" then return chapter end
    local url = trim(chapter._raw_url)
    if url == "" then url = trim(chapter.url) end
    if url == "" then return nil end
    local cached = platform_fields[url]
    if cached ~= nil then return cached ~= false and cached or nil end
    local fields = false
    if type(Shushan.parseUrl) == "function" then
        local ok, action, values = pcall(Shushan.parseUrl, Shushan, url)
        if ok and action == "chapter" and type(values) == "table" then fields = values end
    end
    if platform_field_count > 400 then
        platform_fields, platform_field_count = {}, 0
    end
    platform_fields[url] = fields
    platform_field_count = platform_field_count + 1
    return fields ~= false and fields or nil
end

--[[--
识别章节属于哪个段评平台，并取出协议需要的 book / chapter 标识。

返回 platform, book_id, chapter_id, extra；不是支持的平台时返回 nil。
extra 目前只有七猫用得上：{ item_id, content_md5 } —— 计数接口要多传
content_md5，评论接口要用 item_id 定位章节。
]]--
function ParaComments.platform(chapter)
    local fields = chapterFields(chapter)
    if not fields then return nil end
    local source_name = trim(fields.source)
    if source_name == "" then return nil end
    local curl = trim(fields.curl)
    for _, platform in ipairs(PLATFORMS) do
        if source_name:find(platform.match, 1, true) then
            local book_id = trim(fields[platform.book_field])
            local chapter_id = trim(fields[platform.chapter_field])
            local extra = nil
            if platform.ids_from_curl then
                -- 目录给的原始章节 url 是这两项的唯一来源（见 PLATFORMS 注释）。
                if chapter_id == "" then chapter_id = queryValue(curl, "item_id") end
                if book_id == "" then book_id = queryValue(curl, "book_id") end
                extra = {
                    item_id = chapter_id,
                    content_md5 = queryValue(curl, "content_md5"),
                }
            end
            if book_id ~= "" and chapter_id ~= "" then
                return platform, book_id, chapter_id, extra
            end
        end
    end
    return nil
end

function ParaComments.platformLabel(code)
    for _, platform in ipairs(PLATFORMS) do
        if platform.code == code then return platform.label end
    end
    return nil
end

--[[--
七猫的段落指纹 = md5(段落原文)[:8]。

口径是实测出来的（2026-09-19，《全球灾变之末日游戏》第 1 章 198 段）：
后端 /para 给的 198 个 paragraph_id 里，用「去掉首尾空白的段落原文」算 md5
能命中 196 个，而且命中项与段落顺序逐一对齐；直接用未处理的原文只命中 1 个。

关键在首尾空白：七猫正文里每个段落都以**两个全角空格**（U+3000）开头，
而 Lua 的 `%s` 只认 C locale 的 ASCII 空白、**不匹配 U+3000** —— 所以这里把
全角空格和 NBSP 的字节显式写进字符类，只靠 Util.trim 是不够的。

剩下 2 段对不上，是后端库里的段落文本与当前正文有细微差异（同书不同版本），
属正常漂移：那两段不出气泡，其余照常显示。
]]--
local QM_EDGE_BYTES = "[%s\194\160\227\128\128]"

function ParaComments.qmFingerprint(paragraph)
    local body = text(paragraph)
    if body == "" then return "" end
    body = body:gsub("^" .. QM_EDGE_BYTES .. "+", ""):gsub(QM_EDGE_BYTES .. "+$", "")
    if body == "" then return "" end
    if type(Digest.md5) ~= "function" then return "" end
    local ok, value = pcall(Digest.md5, Digest, body)
    if not ok or type(value) ~= "string" or #value < 8 then return "" end
    return value:sub(1, 8)
end

--[[--
把七猫「按内容指纹给的计数」换算成「按段落号给的计数」。

by_fingerprint 是 `{ [md5 前 8 位] = 评论数 }`，返回 `{ [0 基段落号] = 评论数 }`，
与番茄 / QQ 的计数表格式一致 —— 分页器和 ReaderView 不需要知道平台差异。

同一段文本在一章里可能重复出现（比如同一句话写两遍），那时两个位置都会挂上
同一个计数：指纹相同本来就意味着后端给的是同一份评论。
]]--
function ParaComments.qmCountsByParagraph(by_fingerprint, paragraphs)
    local counts = {}
    if type(by_fingerprint) ~= "table" or type(paragraphs) ~= "table" then return counts end
    for index = 1, #paragraphs do
        local fingerprint = ParaComments.qmFingerprint(paragraphs[index])
        if fingerprint ~= "" then
            local count = tonumber(by_fingerprint[fingerprint])
            if count and count > 0 then counts[index - 1] = count end
        end
    end
    return counts
end

-- 缓存键：同一本书的同一章在不同镜像上是两份独立数据，镜像写进键里；
-- 换镜像（原生源自己会轮换）后旧数据不会被顶替。
local function cacheKey(book, chapter_index, host)
    return tostring(book and book.id or "?") .. ":"
        .. tostring(chapter_index or 0) .. ":" .. Util.hashId(tostring(host or "auto"))
end

local function commentsKey(book, chapter_index, host, pid)
    return cacheKey(book, chapter_index, host) .. ":" .. tostring(pid)
end

-- 切换书籍 / 重开阅读器 / 换服务器时丢掉内存态。磁盘缓存不受影响。
function ParaComments.reset()
    counts_cache = {}
    platform_fields, platform_field_count = {}, 0
end

-- 当前镜像地址（只用于缓存分桶与界面显示；实际请求由 Shushan 轮换）。
function ParaComments.host(source)
    if type(source) ~= "table" or type(Shushan.credentials) ~= "function" then
        return nil
    end
    local ok, credentials = pcall(Shushan.credentials, Shushan, source)
    if not ok or type(credentials) ~= "table" then return nil end
    local host = trim(credentials.host)
    if host ~= "" then return host end
    return nil
end

--[[--
当前生效的镜像标识，用来给「哪一代数据」打标。

原生源在请求成功时会记住这台镜像（Shushan:_rememberHost 写进 source.login_info），
所以镜像轮换后这个值会跟着变。没有记忆值时统一算作 "auto"，免得 nil 参与比较
让「这一代」和「另一代」分不清。
]]--
function ParaComments.hostKey(source)
    return ParaComments.host(source) or "auto"
end

function ParaComments.hostLabel(host)
    local value = trim(host):gsub("^https?://", ""):gsub("/+$", "")
    return value ~= "" and value or "自动"
end

--[[--
这本书 / 这一章能不能做段评。只做本地判定，不发请求。
]]--
function ParaComments.isSupported(book, chapter_index)
    local chapter = book and book.chapters and book.chapters[chapter_index]
    local platform = ParaComments.platform(chapter)
    return platform ~= nil
end

-- 用原生通道发一个 GET，返回 JSON 表（镜像轮换 / 登录刷新由 Shushan 负责）。
local function requestJson(source, path, validate)
    if type(Shushan.requestJson) ~= "function" then
        return nil, "原生书山驱动不可用"
    end
    local payload, host_or_err = Shushan:requestJson(source,
        function(host) return host .. path end,
        validate,
        { timeout = ParaComments.TIMEOUT })
    if not payload then return nil, tostring(host_or_err or "请求失败") end
    local host = type(host_or_err) == "string" and host_or_err or nil
    return payload, nil, host
end

--[[--
这个平台的评论接口是不是「一次给全、没有下一页」。

  QQ   分页参数被无视（page / cursor / count / offset 实测都不生效）。
  七猫 `paragraph_more` 实测无论怎么传 next_id / hot 都回 0 条，而
        `paragraph_first` 的顶层 next_id 一直是空 —— 网页端的「加载更多」
        因此也出不来。

两家都续不了，所以对它们而言「继续加载」这个语义不成立。
]]--
local function platformSingleShot(platform)
    if type(platform) ~= "table" then return false end
    return platform.code == "qq" or platform.code == "qm"
end

--[[--
缓存记录 -> 分页信息。旧版缓存（0.17.17 之前）只有 20 条且没有续拉位置，
此时当作「还能继续拉」，读者点一次「继续加载」就能拿到后面的。
]]--
local function pageInfo(record, platform)
    local list = record.list or {}
    local next_cursor = tonumber(record.next_cursor)
    local has_more = record.has_more
    if next_cursor == nil then next_cursor = #list end
    if has_more == nil then
        -- 番茄：没有续拉位置也当「还有」——点一次就能把后面的取回来。
        -- 一次给全的平台：说「还有」只会让同一批评论被追加一遍。
        has_more = not platformSingleShot(platform)
    end
    return { next_cursor = next_cursor, has_more = has_more == true }
end

local function readDiskCache(kind_key, ttl)
    if type(Storage.readCache) ~= "function" then return nil end
    local ok, value = pcall(Storage.readCache, Storage, ParaComments.CACHE_KIND, kind_key, ttl)
    if ok and type(value) == "table" then return value end
    return nil
end

local function writeDiskCache(kind_key, value)
    if type(Storage.writeCache) ~= "function" then return end
    pcall(Storage.writeCache, Storage, ParaComments.CACHE_KIND, kind_key, value)
end

-- 段评是阅读的附加信息：后端不可用、书源未登录都只记日志，不打断阅读。
local function reportFailure(stage, err)
    logger.warn("Leko para review", stage, tostring(err))
end

--[[--
本章「哪些段有评论」。返回值是 `{ [paragraph_id] = comment_count }`（pid 从 0 起）。

options.force = true 时忽略内存 / 磁盘缓存重新拉取。
options.paragraphs = model.paragraphs。**七猫必需**：后端给的是段落内容指纹，
要先拿本地段落算出指纹才能挂回段号（见 qmCountsByParagraph）；番茄 / QQ 的
paragraph_id 本来就是段号，用不上。只在真要发请求时才会要求它（命中缓存不必）。
]]--
function ParaComments.ensureCounts(book, chapter_index, source, options)
    options = options or {}
    if not book or not source then return nil, "缺少书籍或书源" end
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return nil, "章节不存在" end
    local platform, book_id, chapter_id, extra = ParaComments.platform(chapter)
    if not platform then return nil, "该章节所在平台没有段评（目前支持番茄 / 七猫 / QQ阅读）" end
    if platform.ids_from_curl and trim(extra and extra.content_md5) == "" then
        -- 计数接口要 content_md5，缺了后端会直接拒；早说比让读者等一次失败好。
        return nil, "目录里没有这一章的 content_md5，暂时读不了七猫段评"
    end

    -- 先定镜像再查缓存：缓存是按镜像分开存的，顺序反了就会把别的镜像的
    -- 数据当成自己的。
    local host = ParaComments.host(source)
    local key = cacheKey(book, chapter_index, host)
    local entry = counts_cache[key]
    if entry and not options.force then return entry.counts end

    if not options.force then
        local disk = readDiskCache("counts:" .. key, ParaComments.COUNTS_TTL)
        if disk and type(disk.counts) == "table" then
            counts_cache[key] = { counts = disk.counts }
            return disk.counts
        end
    end

    if platform.ids_from_curl and type(options.paragraphs) ~= "table" then
        return nil, "缺少本章段落文本，无法把七猫段评挂回段落"
    end

    local path = "/para?source=" .. platform.code
        .. "&book_id=" .. tostring(book_id)
        .. "&chapter_id=" .. tostring(chapter_id)
    if platform.ids_from_curl then
        path = path .. "&content_md5=" .. extra.content_md5
    end
    local payload, err = requestJson(source, path, function(value)
        return type(value.data) == "table" and type(value.data.list) == "table"
    end)
    if not payload then
        reportFailure("counts request failed", err)
        return nil, err
    end

    local counts = {}
    if platform.ids_from_curl then
        --[[--
        七猫的 paragraph_id 是内容指纹，不是段号：先收成 `{指纹 = 计数}`，
        再拿本地段落换算段号。

        换算是 O(段数) 次纯 Lua md5（一章几百段，在子进程里跑），换来的是
        「后端分段与本地一致」这件事不再需要假设 —— 段号对不上的两段自然
        落空，而不会把评论整体错位挂到别的段上。
        ]]--
        local by_fingerprint = {}
        for _, item in ipairs(payload.data.list) do
            if type(item) == "table" then
                local fingerprint = trim(item.paragraph_id)
                local count = tonumber(item.comment_count) or 0
                if fingerprint ~= "" and count > 0 then
                    by_fingerprint[fingerprint] = count
                end
            end
        end
        counts = ParaComments.qmCountsByParagraph(by_fingerprint, options.paragraphs)
    else
        for _, item in ipairs(payload.data.list) do
            if type(item) == "table" then
                local pid = tonumber(item.paragraph_id)
                local count = tonumber(item.comment_count) or 0
                -- pid 必须是 0 基非负整数；0 条评论的段落在页面上不留标记。
                if pid and pid >= 0 and pid == math.floor(pid) and count > 0 then
                    counts[pid] = count
                end
            end
        end
    end

    counts_cache[key] = { counts = counts }
    writeDiskCache("counts:" .. key, { counts = counts })
    return counts
end

--[[--
后端回传的「原文段落」是否可用。

实测（2026-09）：番茄的 `para_src_content` 有时回的是 `"1"` 这类短 token 或空串，
QQ 的 `lineContent` 常为空 —— 都不是段落原文。短于 8 个字的都不当段落，
免得把噪声当成段落原文。
]]--
local function sanitizeParaText(value)
    local body = trim(text(value))
    if Util.utf8Length(body) < 8 then return "" end
    return body
end

-- 番茄评论条目 -> 统一结构
local function parseFanqieComments(payload)
    local list = {}
    local data = payload.data
    for _, entry in ipairs(type(data) == "table" and data.data_list or {}) do
        local comment = type(entry) == "table" and entry.comment or nil
        if type(comment) == "table" then
            local common = type(comment.common) == "table" and comment.common or {}
            local content = type(common.content) == "table" and common.content or {}
            local base = type(common.user_info) == "table" and common.user_info or {}
            base = type(base.base_info) == "table" and base.base_info or {}
            local stat = type(comment.stat) == "table" and comment.stat or {}
            local body = trim(text(content.text))
            -- 纯图片评论没有文字，当前是纯文字阅读器，直接跳过。
            if body ~= "" then
                local name = trim(text(base.user_name))
                list[#list + 1] = {
                    name = name ~= "" and name or "匿名",
                    text = body,
                    likes = tonumber(stat.digg_count) or 0,
                    author = base.is_author == true,
                    timestamp = tonumber(common.create_timestamp) or 0,
                }
            end
        end
    end
    return list, sanitizeParaText(data and data.para_src_content)
end

-- QQ阅读评论条目 -> 统一结构
local function parseQqComments(payload)
    local list = {}
    local para_text = ""
    for _, comment in ipairs(type(payload.comments) == "table" and payload.comments or {}) do
        if type(comment) == "table" then
            local body = trim(text(comment.replyContent))
            if body ~= "" then
                local name = trim(text(comment.nick))
                list[#list + 1] = {
                    name = name ~= "" and name or "匿名",
                    text = body,
                    likes = tonumber(comment.agree) or 0,
                    author = tonumber(comment.isManito) == 1,
                    timestamp = math.floor((tonumber(comment.createTime) or 0) / 1000),
                }
            end
            -- 整段原文（对齐校验用）：取第一条带回传的段落文本。
            if para_text == "" then
                local line = sanitizeParaText(comment.lineContent)
                if line == "" then line = sanitizeParaText(comment.originalContent) end
                if line ~= "" then para_text = line end
            end
        end
    end
    return list, para_text
end

--[[--
七猫评论 -> 统一结构。

响应把一段的评论分成两区：hot_zone（热门，实测 5 条）与 time_zone（最新，实测
30 条），合起来 35 条。网页端也是 `[...hot, ...time]` 之后按 comment_id 去重，
这里照做：先 hot、后 time，重复的只留第一条出现的位置。

没有分页：`/paras/proxy_qmidea?action=paragraph_more` 实测无论怎么传 next_id /
hot 都回 0 条，`paragraph_first` 的顶层 next_id 也一直是空 —— 网页端的「加载
更多」因此同样出不来。所以七猫是「一次给全」（与 QQ 一样），首屏即全部。
]]--
local function parseQmComments(payload)
    local list, seen = {}, {}
    local data = payload.data
    if type(data) ~= "table" then return list, "" end
    for _, zone_name in ipairs({ "hot_zone", "time_zone" }) do
        local zone = data[zone_name]
        local comments = type(zone) == "table" and zone.comment_list or nil
        for _, comment in ipairs(type(comments) == "table" and comments or {}) do
            if type(comment) == "table" then
                local body = trim(text(comment.content))
                -- comment_id 实测总是有；万一缺了就用「昵称 + 正文」兜底，
                -- 免得同一批评论在列表里出现两遍。
                local id = trim(text(comment.comment_id))
                if id == "" then id = trim(text(comment.nickname)) .. "\n" .. body end
                -- 纯图片/空评论没有文字，当前是纯文字阅读器，直接跳过。
                if body ~= "" and not seen[id] then
                    seen[id] = true
                    local name = trim(text(comment.nickname))
                    list[#list + 1] = {
                        name = name ~= "" and name or "匿名",
                        text = body,
                        likes = tonumber(comment.like_count) or 0,
                        -- 七猫没有「作者本人」标记（is_god 是神评/加精，语义不同），
                        -- 一律按普通读者处理。
                        author = false,
                        -- comment_time 是「2022-03」「09-14 山东」这类展示串，
                        -- 转不成可靠时间戳；弹窗也不显示时间，给 0。
                        timestamp = 0,
                    }
                end
            end
        end
    end
    -- 只读文字：这里不回传段落原文（接口本来也不给），引文由正文提供。
    return list, ""
end

--[[--
一页番茄评论算不算「可用响应」。

镜像之间可用性并不一致：实测（2026-09-18）v3 会对同一个热段落回
`200 + {"data":{"data_list":[]}}`（连 `common_list_info` 都没有），而同一时刻
v4 正常给 20 条。`Shushan:requestJson` 是「validate 通过就停在当前镜像」，
所以只要 `data` 是表就算通过的话，这一请求会停在 v3、把空页当成结果 ——
读者点开十万条评论的段落依旧只看到 20 条，正是要修的现象。

于是要求响应「要么真有条目，要么明确说了 has_more=false」；不满足就当作
这台镜像没给出数据，交给 Shushan 继续轮换下一台。
]]--
local function fqPageUsable(payload)
    local data = payload.data
    if type(data) ~= "table" or type(data.data_list) ~= "table" then return false end
    if #data.data_list > 0 then return true end
    local info = payload.common_list_info
    if type(info) ~= "table" then info = data.common_list_info end
    -- 空页且服务端明确说「没有更多」才算正常收尾。
    return type(info) == "table" and info.has_more == false
end

--[[--
按平台拉一页评论。返回 list, para_text, next_cursor, has_more, err。

paragraph_key 只有七猫用得上：它按「段落内容指纹」定位，不认段号
（见 qmFingerprint）。番茄 / QQ 忽略它。
]]--
local function fetchCommentPage(platform, book_id, chapter_id, pid, start, source, paragraph_key)
    local path, validate, parse
    if platform.code == "fq" then
        path = "/idea_comment?api=1&book_id=" .. tostring(book_id)
            .. "&item_id=" .. tostring(chapter_id)
            .. "&para=" .. intText(pid)
            .. "&cursor=" .. intText(start)
            .. "&count=" .. intText(ParaComments.PAGE_SIZE)
            .. "&sort=1"
        validate = fqPageUsable
        parse = parseFanqieComments
    elseif platform.code == "qm" then
        if type(paragraph_key) ~= "string" or paragraph_key == "" then
            return nil, nil, nil, nil, "无法定位这一段（七猫按段落内容匹配）"
        end
        -- 七猫没有分页参数，一次给全（见 parseQmComments 的注释）。
        path = "/paras/proxy_qmidea?action=paragraph_first"
            .. "&book_id=" .. tostring(book_id)
            .. "&item_id=" .. tostring(chapter_id)
            .. "&paragraph_id=" .. paragraph_key
        -- 两区都可能空（这一段确实没人评论）。只要 zone 结构在就算有效响应 ——
        -- 否则一个正常的空结果会被当成「这台镜像不行」而白白轮换下去。
        validate = function(value)
            local data = value.data
            if type(data) ~= "table" then return false end
            return type(data.hot_zone) == "table" or type(data.time_zone) == "table"
        end
        parse = parseQmComments
    else
        -- QQ 侧没有分页参数（实测 page/cursor/count/offset 都不生效），
        -- 一次把这一段给全。所以续拉只在番茄上有意义。
        path = "/qq_comment?ajax=1&bid=" .. tostring(book_id)
            .. "&cid=" .. tostring(chapter_id)
            .. "&para=" .. intText(pid)
        validate = function(value) return type(value.comments) == "table" end
        parse = parseQqComments
    end

    local payload, err = requestJson(source, path, validate)
    if not payload then
        reportFailure("comments request failed", err)
        return nil, nil, nil, nil, err
    end

    local list, para_text = parse(payload)
    local next_cursor = start + #list
    local has_more = false
    if platform.code == "fq" then
        -- 实测：游标信息在响应**顶层** common_list_info，
        -- 而 data 里只有 { data_list, para_src_content }。
        local info = payload.common_list_info
        if type(info) ~= "table" then
            info = payload.data and payload.data.common_list_info
        end
        if type(info) == "table" then
            next_cursor = tonumber(info.cursor) or next_cursor
            if info.has_more ~= nil then has_more = info.has_more == true end
        end
        -- 服务端没回 has_more 时按「满一页就还可能有余量」推断。空页到不了
        -- 这里（fqPageUsable 只放行 has_more=false 的空页），所以不必特判。
        if type(info) ~= "table" or info.has_more == nil then
            has_more = #list >= ParaComments.PAGE_SIZE
        end
    end
    return list, para_text, next_cursor, has_more, nil
end

--[[--
取某一段的评论正文。

options.cursor
    续拉提示（= 上次拿到的 page.next_cursor）。只在「本地这批已经覆盖到那里」
    时才从该位置续拉，否则从本地这批的尾部接着拉，绝不交出中间缺条的列表。
    省略表示「首次打开这一段」：缓存有效就直接用缓存，不打网络。
options.force
    true 时忽略磁盘缓存，重新从开头拉。
options.paragraphs
    model.paragraphs。**七猫必需**：它按段落内容指纹定位，要拿本地段落现算指纹
    （见 qmFingerprint）；番茄 / QQ 的 pid 本来就是段号，用不上。

返回 `list, para_text, err, page`，其中 `page = { next_cursor, has_more }`：
`next_cursor` 是下次续拉的起点，`has_more` 表示服务端还有余量。失败时
`list` 为 nil、`err` 是原因（前三位语义与旧版一致，调用方不必改）。

缓存存的是「已经拉到的那一批」以及它的续拉位置，所以「继续加载」不会把
前面几页重新拉一遍，重开弹窗也能直接看到上次拉到的条数。
]]--
function ParaComments.fetchComments(book, chapter_index, source, pid, options)
    options = options or {}
    if not book or not source then return nil, nil, "缺少书籍或书源" end
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return nil, nil, "章节不存在" end
    -- 七猫的 item_id / content_md5 已在 platform() 里从 curl 取好：这里只用得上
    -- chapter_id（= item_id），评论接口不需要 content_md5。
    local platform, book_id, chapter_id = ParaComments.platform(chapter)
    if not platform then
        return nil, nil, "该章节所在平台没有段评（目前支持番茄 / 七猫 / QQ阅读）"
    end

    -- 七猫按内容指纹定位这一段；没有段落文本就换不出指纹，只能如实报错。
    local paragraph_key = ""
    if platform.ids_from_curl then
        local paragraphs = options.paragraphs
        if type(paragraphs) ~= "table" then
            return nil, nil, "缺少本章段落文本，无法定位七猫段评"
        end
        local index = math.floor(tonumber(pid) or 0) + 1
        paragraph_key = ParaComments.qmFingerprint(paragraphs[index])
        if paragraph_key == "" then
            return nil, nil, "这一段没有可用的内容指纹，读不了七猫段评"
        end
    end

    local host = ParaComments.host(source)
    local key = commentsKey(book, chapter_index, host, pid)

    local cached
    if not options.force then
        cached = readDiskCache(key, ParaComments.COMMENTS_TTL)
    end
    if cached and type(cached.list) ~= "table" then cached = nil end

    -- 调用方带了 cursor = 这是「继续加载」，不能拿缓存快照糊弄它。
    local caller_continues = tonumber(options.cursor) ~= nil
    -- 一次给全的平台（QQ / 七猫）一律走缓存：照着 cursor 再拉一次只会把同一批
    -- 评论在尾部追加一遍。番茄则是「没带 cursor 就吃缓存」（TTL 6h，翻回同一段
    -- 不必再打后端）。
    local single_shot = platformSingleShot(platform)
    if cached and (not caller_continues or single_shot) then
        return cached.list, cached.para_text, nil, pageInfo(cached, platform)
    end

    --[[--
    从哪里接着拉。

    缓存永远是 0..n 连续的一段，所以续拉点永远取**缓存尾部**，不看调用方给的
    cursor —— 从已加载区间的中间再拉一次，只会把同一批评论在尾部重复追加
    （缓存是读-改-写，重复条目会一直留在里面）。

    调用方的 cursor 只用来表达「我这不是首次打开」，不参与定位：真正的续拉点
    以服务端游标为准（next_cursor），因为它会跳过被我们丢掉的条目（纯图片
    评论），而 #list 不会。

    实测会遇到：原生源在某次请求里换了镜像，而评论缓存是按镜像分桶的，于是
    「上一次那批」不在当前桶里。此时缓存尾部是 0，这一步自然退化成「首次
    打开」（连拉两页），不会交出一份中间缺了几十条的列表。
    ]]--
    local resume = 0
    if cached then
        resume = tonumber(cached.next_cursor) or #cached.list
    end
    local start = math.max(0, math.floor(resume))

    -- 从 0 开始（首次打开）就多连一页；续拉（caller 带着 cursor 来）只取一页。
    -- 一次给全的平台（QQ / 七猫）本来就只该请求 1 次 —— 第二页拿回来的是同一批。
    local page_budget = (start == 0) and ParaComments.FIRST_OPEN_PAGES or 1
    if single_shot then page_budget = 1 end

    local collected, para_text = {}, nil
    local next_cursor, has_more = start, false
    local extra_error = nil
    for page_index = 1, page_budget do
        local page_list, page_text, page_next, page_more, page_err =
            fetchCommentPage(platform, book_id, chapter_id, pid, next_cursor, source, paragraph_key)
        if not page_list then
            -- 第一页就失败：如实报错（读者点开一段却什么都没有，必须让他
            -- 知道是取不到而不是「这一段没人评论」）。
            if page_index == 1 then return nil, nil, page_err end
            -- 后面几页失败不该连累已经拿到的那一页，更不能因此宣称「到底了」
            -- —— 那正是「点开只有 20 条」的另一半成因。保持「还有更多」，
            -- 读者再点一次「继续加载」就能重试同一游标。
            extra_error = page_err
            has_more = true
            break
        end
        if para_text == nil or para_text == "" then para_text = page_text end
        for index = 1, #page_list do
            collected[#collected + 1] = page_list[index]
        end
        next_cursor = page_next
        has_more = page_more
        if #page_list == 0 or not page_more then break end
    end
    if extra_error then
        reportFailure("comment page failed", extra_error)
    end

    if cached then
        -- 追加到缓存里的那一批后面（缓存只会在尾部变长）。
        for index = 1, #collected do
            cached.list[#cached.list + 1] = collected[index]
        end
        if cached.para_text == nil or cached.para_text == "" then
            cached.para_text = para_text
        end
    else
        cached = { list = collected, para_text = para_text }
    end
    cached.next_cursor = next_cursor
    cached.has_more = has_more
    -- 一条都没取到就别写缓存：大概率是服务端抽风（实测出现过整个请求被拒），
    -- 写进去只会让读者在 TTL 内一直看到空。
    if #cached.list > 0 then
        writeDiskCache(key, cached)
    end
    return cached.list, cached.para_text, nil, pageInfo(cached, platform)
end

return ParaComments
