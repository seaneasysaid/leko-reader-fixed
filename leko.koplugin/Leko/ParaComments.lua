--[[--
段评（段落评论）数据层 —— 原生书山驱动版（v6 接口，2026-11-19）。

支持五个平台（chapter.source 为书山给的中文源名）：

  番茄小说 / QQ阅读 / 七猫 / 书旗 / 半夏
  —— 直接把 chapter.source 作为 /api/comment 的 source 参数（服务端认中文名）。

接口（书山 v6，全部带 Bearer JWT，见 Leko/ShushanAuth.lua）：

  计数（气泡）  后端不再提供独立的段落计数接口（旧 /para 全节点 404）。
                计数随正文一起返回：POST /api/content 带 review=on 时，
                每一段正文末尾内嵌一个 SVG 气泡 <img>，base64 里的 <text>
                就是该段评论数。本模块从正文解析气泡得到 {段号=评论数}。
                —— 因此 ensureCounts 需要 options.content（本章正文 HTML/文本）；
                若调用方没给，则用章节 url 经 Shushan:chapter 现取一次并解析。

  评论正文      GET /api/comment?source=<中文源名>&tab=paras
                     &book_id=<bid>&item_id=<cid>&para=<0基段号>
                     &offset=<n>&count=20&sort=hot
                -> {code:0, data:{items:[{id,content,user_name,likes,time,
                    para_text,quote,replies,reply_list,segments,...}],
                    total, has_more, next}}
                续拉用 offset（服务端返回的 next 是下一页的 offset）。

鉴权：/api/comment 需要 SPA JWT（Authorization: Bearer），JWT 由
Leko/ShushanAuth.lua 用已存的邮箱/密码 + 可计算的 altcha PoW 自动获取并缓存
（约 7 天有效，过期自动重登），读者无感。

⚠️ 历史：v5 的 /idea_comment、/qq_comment、/paras/proxy_qmidea 在 v6 全部
节点恒 404，已彻底废弃；QQ 的「毫秒时间戳游标」也随之成为历史 —— v6 统一
用 offset 分页。保留下面的 pid 基准注释仅为说明段落坐标语义。

`paragraph_id` 的含义分两种：

  * 番茄 / QQ 都是**正文非空段落**的序号，但**基准不同**：
    番茄是 0 基（第 pid 段 = model.paragraphs[pid + 1]）；
    QQ 是 **1 基，且 pid 0 专门表示章节标题**（不是正文段落）。
    基准记在 PLATFORMS 的 `pid_base` 上，由 toBackendPid / fromBackendPid 统一换算，
    模块对外（Paginator / ReaderView / 缓存）**一律只用 0 基段号**；
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
local LuaSettings = require("luasettings")
local Shushan = require("Leko/Shushan")
local ShushanAuth = require("Leko/ShushanAuth")
local Storage = require("Leko/Storage")
local Util = require("Leko/Util")
local CryptoCompat = require("Leko/CryptoCompat")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local ParaComments = {}

-- 计数缓存拆成两档 TTL，因为这两种「事实」的半衰期完全不同：
--   * 有评论：评论数是慢变量，7 天内几乎不会从「有」变「没有」；
--   * 本章确认无评论：新书 / 新章刚上架时评论是陆续冒出来的，记太久会让
--     气泡一直不出现，所以只认 12 小时。
ParaComments.COUNTS_TTL_HIT = 7 * 24 * 60 * 60
ParaComments.COUNTS_TTL_EMPTY = 12 * 60 * 60
-- 评论正文 TTL 稍长，翻回同一段不该再打一次后端。
ParaComments.COMMENTS_TTL = 6 * 60 * 60
-- 单次请求取多少条评论。
--
-- 实测（2026-09-18，书山 /idea_comment）：服务端只稳定接受 20 ——
-- count=30 / 40 一律回 `{"error":"获取评论失败"}`，count=50 三成概率挂住
-- 20 秒以上（同一台镜像时好时坏），只有 count=20 是 3/3 稳定（2–4 秒）。
-- 所以「看到更多」不能靠调大这一页，只能靠 cursor 续拉。
ParaComments.PAGE_SIZE = 20

--[[--
哪些平台的「段评正文」在书山 v6 后端是空的（气泡计数有、点开没有）。

实测（2026-11-20，v4 镜像，真实账号）：
  · 书旗《赤心巡天》book_id=9162887，ch1/11/504：`tab=paras` 恒定
    `code=0, total=0, items=[], quote.text=""`；同一章 `tab=chapter` 有评论。
  · 七猫《剑来》book_id=143170，ch0/1/2：同样恒空；`tab=chapter` 回 1092 条。
  · 番茄《剑来，给我斩开这方天地》对照：para=0 有 68 条、para=1 有 10 条 ——
    说明接口本身没坏，只是 sq / qm 的 paras 通道没有数据。

气泡计数来自 `/api/content?review=on`（上游正文自带的 SVG 计数），和评论正文
是两条不同的上游通路：前者通、后者没通。所以「有气泡但点开空白」不是网络问题，
也不该让读者以为是这一段没人评论。

这张表只用于**文案**（说清楚为什么拿不到），不阻止请求 —— 后端哪天真接上了，
读者点一次就能拿到，不需要发版。
]]--
ParaComments.PARAS_EMPTY_PLATFORMS = {
    -- 七猫 2026-11-20 已修：v6 的 paras 要的是段落内容指纹，不是段号
    -- （见 fetchCommentPage），改对之后单段能回上万条。
    -- 书旗 2026-11-20 已改走 tab=chapter + quote 匹配（见 fetchSqComments）。
}

function ParaComments.parasEmptyPlatformLabel(code)
    if not ParaComments.PARAS_EMPTY_PLATFORMS[code] then return nil end
    return ParaComments.platformLabel(code) or code
end

-- 首次打开时一次连拉几页。
--
-- 一页只有 20 条，读者点开弹窗却只看到 20 条就是这个问题。首屏连拉两页能
-- 一次给出 40 条；续拉走单页 —— 那个按钮的语义是「再来一批」，一次等两页
-- 没有意义。
--
-- 代价说清楚：服务端每页稳定 4–5 秒，所以首屏要等约 9 秒。这个等待必须放在
-- 子进程里（见 Leko/AsyncParaReview），否则整台机器会僵住约 9 秒。
ParaComments.FIRST_OPEN_PAGES = 2
-- QQ 评论缓存的格式版本。续拉位置从「条数偏移」改成「毫秒时间戳游标」后
--  升到 2：旧缓存里的 next_cursor 是 11、22 这种小整数，当时间戳发回去会被
--  服务端当作极早的时间点、拉回首屏，于是同一批评论被反复追加。检测到版本
--  不符就把整条缓存丢掉重新从首屏拉一次（一次性代价，TTL 6h 内只发生一次）。
-- v6 换了接口与解析格式（3 家 -> 5 家、offset 游标、JWT 鉴权）。旧缓存里的
-- 条目无法复用，升到 3 让其自然失效重拉（一次性代价）。
-- 4：七猫改用段落指纹定位（此前按段号请求恒空，空结果也写进了缓存）。
local COMMENTS_CACHE_VERSION = 4
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
--
-- ⭐ pid_base（改这里前务必先读）：模块内部一律用 **0 基段号**
-- （第 k 段 = 正文非空行的第 k 行，pid = k - 1），Paginator 与 ReaderView 都按
-- 这个约定查 model.para_counts。但各家后端的 `paragraph_id` 基准并不一致，
-- pid_base 记录的正是「后端基准」，换算只在本模块里做：
--
--   fq 番茄   pid = 0 基（正文第 pid 行）          → pid_base = 0
--   qq QQ阅读 pid = 1 基，且 **pid 0 是章节标题**   → pid_base = 1
--   qm 七猫   pid 是内容指纹，不用段号             → 无所谓（走 qmFingerprint）
--
-- 证据出处 = 书源 v5.53 的 jsLib.getComments()：
--     if (sourceType == 'qq') {
--         if (paraId == 0) { hasTitleComment = true; … return; }   // 标题评论
--         lineIndex = parseInt(paraId) - 1;                        // 1 基
--     } else if (sourceType == 'qm') { lineIndex = index;
--     } else { lineIndex = sourceType == 'jj' ? parseInt(paraId) - 1 : parseInt(paraId); }
--                                                       ↑晋江 1 基   ↑番茄 0 基
-- 后端实测佐证（2026-10-11，《娱乐：朴智妍拉我进圈》bookid=53181878，扫 39 章）：
--   pid=0 有评论的章节 0/39（0 基的话第一段不可能章章为空）
--   pid=1 有评论的章节 9/39；ch10 段数 74 且 maxpid=74（1 基下末段正是 pid=段数）
--
-- ⚠️ 曾经的 bug：三平台统一按 0 基发 para，于是 QQ 每一段的评论都整体前移一段
-- （第 k 段显示成第 k-1 段的评论）。别再把 pid_base 拿掉。
local PLATFORMS = {
    {
        code = "fq", label = "番茄", source_name = "番茄小说",
        match = "番茄",
        book_field = "bookid", chapter_field = "itemid",
        pid_base = 0,
    },
    {
        code = "qq", label = "QQ阅读", source_name = "QQ阅读",
        match = "QQ",
        book_field = "bookid", chapter_field = "itemid",
        pid_base = 0, -- v6 统一 0 基段号（见下 v6 说明）
    },
    {
        code = "qm", label = "七猫", source_name = "七猫",
        match = "七猫",
        book_field = "bookid", chapter_field = "itemid",
        ids_from_curl = true,
        pid_base = 0,
        -- v6 的 /api/comment 对七猫仍按「段落内容指纹」定位（不是段号），
        -- 见 fetchCommentPage 里的实测说明。
        para_mode = "fingerprint",
    },
    {
        code = "sq", label = "书旗", source_name = "书旗",
        match = "书旗",
        book_field = "bookid", chapter_field = "itemid",
        pid_base = 0,
    },
    {
        code = "bx", label = "半夏", source_name = "半夏",
        match = "半夏",
        book_field = "bookid", chapter_field = "itemid",
        pid_base = 0,
    },
}

--[[--
后端 pid ↔ 模块内部 0 基段号 的换算（定义在 intText 之后，见下方）。

* `toBackendPid(platform, pid)`：内部段号 → 发给后端的 `para` 值。
* `fromBackendPid(platform, raw_pid)`：后端 `paragraph_id` → 内部段号；
  该 pid 属于「非正文」（QQ 的标题槽）时返回 nil，调用方必须丢弃。

基底差由 platform.pid_base 决定：pid_base = 1 的平台（QQ），后端 pid 1 才是
正文第 1 段，且 pid 0 被标题占用。
]]--

local function text(value)
    return tostring(value == nil and "" or value)
end

local function trim(value)
    return Util.trim(text(value))
end

-- URL query 编码（source 是中文名、book_id 可能含大写，必须编码）。
local function percent_encode(value)
    return (text(value):gsub("[^A-Za-z0-9%-%._~]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
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
    -- ⚠️ 不能用 "%d"：32 位 LuaJIT 的 int 装不下 QQ 的毫秒时间戳游标
    -- （约 1.7e12），会溢出成负数或 0，续拉直接打回最前面一页。
    -- "%.0f" 走 double（能精确表示到 2^53），大数小数都输出纯十进制整数串。
    return string.format("%.0f", math.floor(number))
end

--[[--
后端 pid ↔ 模块内部 0 基段号 的换算。

* `toBackendPid(platform, pid)`：内部段号 → 发给后端的 `para` 值。
* `fromBackendPid(platform, raw_pid)`：后端 `paragraph_id` → 内部段号；
  该 pid 属于「非正文」（QQ 的标题槽）时返回 nil，调用方必须丢弃。

基底差由 platform.pid_base 决定（见 PLATFORMS 的注释）：pid_base = 1 的平台
（QQ）后端 pid 1 才是正文第 1 段，且 pid 0 被章节标题占用 —— 少加这个 offset
就会让每一段的评论整体前移一段。
]]--
local function toBackendPid(platform, pid)
    local base = tonumber(platform and platform.pid_base) or 0
    return intText((tonumber(pid) or 0) + base)
end

local function fromBackendPid(platform, raw_pid)
    local number = tonumber(raw_pid)
    if not number or number ~= math.floor(number) then return nil end
    local base = tonumber(platform and platform.pid_base) or 0
    -- pid_base = 1：后端 0 是标题槽，不映射到任何正文段落。
    if number < base then return nil end
    return number - base
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

--[[--
本章计数在磁盘上的位置：`<book_cache>/<book_id>/_pc_<item_id>.lua`。

按章分文件，而不是把整本书塞进一个总表：

  * 一章的计数只有几百字节，分开存就自然做到「读到第几章缓存到第几章」；
  * 单章写坏 / 解析失败只影响那一章，不会把整本书的缓存一起拖下水；
  * 文件名带 item_id，换书源节点（host）也不会互相覆盖——item_id 是后端
    的章节身份，比本地章节序号稳。

item_id 取不到时退回章节 url 的 hash：v5 老章节描述符里没有 item_id，
但 url 逐字节稳定，同样能当身份用。
]]--
local function countsPath(book, chapter, values)
    local item = values and Util.trim(values.itemid or "") or ""
    if item == "" then item = Util.trim(chapter and chapter.itemid or "") end
    if item == "" then item = Util.hashId(tostring(chapter and chapter.url or "?")) end
    item = tostring(item):gsub("[^%w_%-]", "_")
    local dir = Util.joinPath(Storage:getCacheDir(ParaComments.CACHE_KIND),
        tostring(book and book.id or "?"))
    return Util.joinPath(dir, "_pc_" .. item .. ".lua")
end

-- 读一章的计数。TTL 按内容决定（有评论 7 天 / 无评论 12 小时），所以必须
-- 先读出来再判新旧，不能像通用缓存那样把 ttl 传进去。
-- 计数缓存的格式版本。
-- 2：段号改为「气泡所在段落」（旧版按第几个气泡编号，服务端只给有评论的段
--    插气泡时整体错位 —— 书旗 228 段只有 5 个气泡，旧缓存里是 0..4）。
-- 旧缓存直接丢弃重算，不然错位的气泡会一直留到 TTL 过期。
local COUNTS_FORMAT = 2

local function readCountsFile(path)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, settings = pcall(LuaSettings.open, LuaSettings, path)
    if not ok or type(settings) ~= "table" then return nil end
    local data = settings.data or {}
    if tonumber(data.counts_format) ~= COUNTS_FORMAT then return nil end
    local counts = data.counts
    if type(counts) ~= "table" then return nil end
    local updated = tonumber(data.updated_at) or 0
    local ttl = next(counts) ~= nil and ParaComments.COUNTS_TTL_HIT or ParaComments.COUNTS_TTL_EMPTY
    if updated <= 0 or os.time() - updated > ttl then return nil end
    return counts
end

-- 只在取数成功后调用。请求失败 / 登录失败一律不落盘，下次照常重试
-- ——把失败写成「本章 0 条」会让气泡整整 12 小时不出现。
local function writeCountsFile(path, counts)
    pcall(Util.mkdirp, Util.dirname(path))
    local ok, settings = pcall(LuaSettings.open, LuaSettings, path)
    if not ok or type(settings) ~= "table" then return false end
    settings.data = { updated_at = os.time(), counts = counts, counts_format = COUNTS_FORMAT }
    local saved = pcall(settings.flush, settings)
    return saved == true
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

-- 用原生通道发一个带 SPA JWT 的 GET，返回 JSON 表（镜像轮换 / 凭据刷新由
-- Shushan 负责；JWT 获取与过期重登由 ShushanAuth 负责）。
-- v6 段评接口需要 `Authorization: Bearer <jwt>`，所以不能直接用 Shushan 的
-- 默认签名头 —— 这里借用它的 requestJson 走廊，在 extra headers 里加 Bearer。
local function requestJson(source, path, validate)
    if type(Shushan.requestJson) ~= "function" then
        return nil, "原生书山驱动不可用"
    end
    local jwt, jwt_err = ShushanAuth:jwt(source)
    if not jwt then return nil, jwt_err or "段评登录失败" end
    local payload, host_or_err = Shushan:requestJson(source,
        function(host, headers)
            headers["Authorization"] = "Bearer " .. jwt
            headers["Accept"] = "application/json"
            return host .. path
        end,
        validate,
        { timeout = ParaComments.TIMEOUT })
    if not payload then return nil, tostring(host_or_err or "请求失败") end
    local host = type(host_or_err) == "string" and host_or_err or nil
    return payload, nil, host
end

--[[--
从 review=on 的正文里解析每段评论数。

服务端在**有评论的段落**末尾追加一个 SVG 气泡 <img>，base64 里的 <text>N</text>
就是这一段的评论数。

⚠️ 段号必须按「气泡所在段落」算，不能按「第几个气泡」算。实测（2026-11-20，
书旗《赤心巡天》ch1，228 段）服务端只插了 5 个气泡，分别落在第 20/49/62/166/201
段；按出现顺序编号会得到 pid 0..4，气泡显示在前五个段上、点开请求的也是前五段，
既错位又永远拿不到正文。

于是这里直接用 Util.splitParagraphs 切段 —— 与 BookService 生成
model.paragraphs 用的是同一个函数，段号天然对齐（0 基，与 Paginator /
ReaderView 的坐标一致）。

base64 前缀后必须是纯 base64 字符：SVG 模板里含 `${font}` 之类占位符，但
那些出现在解码后的文本里，不影响 base64 段本身。
]]--
function ParaComments.countsFromContent(content)
    local counts = {}
    local body = text(content)
    if body == "" then return counts end
    local paragraphs = Util.splitParagraphs(body)
    for index = 1, #paragraphs do
        local encoded = paragraphs[index]:match("data:image/svg%+xml;base64,([A-Za-z0-9+/]+)")
        if encoded then
            local ok, decoded = pcall(function()
                return CryptoCompat.base64Decode(encoded .. string.rep("=", (4 - #encoded % 4) % 4))
            end)
            if ok and decoded then
                local number = text(decoded):match(">(%d+)</text>")
                local count = tonumber(number)
                if count and count > 0 then counts[index - 1] = count end
            end
        end
    end
    return counts
end

--[[--
这个平台的评论接口是不是「一次给全、没有下一页」。

  七猫 `paragraph_more` 恒定回 44010102「请求参数错误」，且 `paragraph_first`
        的响应里从没有 next_id —— 网页端的「加载更多」按钮因此永远不显示
        （2026-11-07 重新实测确认，见项目笔记）。

  QQ 曾经也在这份名单里，2026-11-07 翻案：/qq_comment 支持
        `cursor=<nextCursor>`，值是**毫秒时间戳**（上一页最早一条的
        createTime），不是条数偏移。当年拿 cursor=20 去试，服务端把它当成
        极小时间戳，看起来「不生效」；改成时间戳后实测连翻 7 页、createTime
        严格递减、评论 ID 无重复。现在 QQ 与番茄一样走续拉。

v6 起 5 家平台统一走 /api/comment 的 offset 分页，全部支持续拉 ——
这个函数恒为 false（保留是为了不改动调用它的缓存分页逻辑）。
]]--
local function platformSingleShot(platform)
    return false
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
        -- 能续拉的平台（番茄 / QQ）：没有续拉位置也当「还有」——点一次就能
        -- 把后面的取回来。七猫一次给全：说「还有」只会让同一批被追加一遍。
        has_more = not platformSingleShot(platform)
    end
    return { next_cursor = next_cursor, has_more = has_more == true,
        -- 服务端这个平台压根没有 paras 数据（见 PARAS_EMPTY_PLATFORMS）。
        -- 只影响弹窗文案，不影响「继续加载」是否可点。
        unsupported = record.unsupported == true,
        platform_label = ParaComments.platformLabel(platform.code) }
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
本章「哪些段有评论」。返回值是 `{ [paragraph_id] = comment_count }`（**0 基段号**）。

options.force = true 时忽略内存 / 磁盘缓存重新拉取。
options.paragraphs = model.paragraphs。**七猫必需**：后端给的是段落内容指纹，
要先拿本地段落算出指纹才能挂回段号（见 qmCountsByParagraph）；番茄 / QQ 用不上
（它们的 pid 是段号，基准差由 fromBackendPid 换算）。
]]--
function ParaComments.ensureCounts(book, chapter_index, source, options)
    options = options or {}
    if not book or not source then return nil, "缺少书籍或书源" end
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return nil, "章节不存在" end
    local platform = ParaComments.platform(chapter)
    if not platform then return nil, "该章节所在平台没有段评（目前支持番茄 / QQ阅读 / 七猫 / 书旗 / 半夏）" end

    local host = ParaComments.host(source)
    local key = cacheKey(book, chapter_index, host)
    local entry = counts_cache[key]
    if entry and not options.force then return entry.counts end

    -- 章节身份（item_id）既决定缓存文件名，也是后端认的章节标识，先解析一次。
    local chapter_values = nil
    if chapter.url then
        local ok, action, values = pcall(Shushan.parseUrl, Shushan, chapter.url)
        if ok and action == "chapter" and type(values) == "table" then chapter_values = values end
    end
    local path = countsPath(book, chapter, chapter_values)

    if not options.force then
        local disk = readCountsFile(path)
        if disk then
            counts_cache[key] = { counts = disk }
            return disk
        end
    end

    -- v6 计数来自 review=on 的正文气泡。优先用调用方给的正文（ReaderView
    -- 已经渲染本章时可直接传入，零额外请求）；否则经 Shushan 现取一次。
    local content = options.content
    if type(content) ~= "string" or content == "" then
        if not chapter_values then return nil, "无法解析章节地址，取不到段评计数" end
        local ok, fetched = pcall(function()
            return Shushan:chapterWithReview(source, chapter_values, {
                timeout = options.timeout,
                max_hosts = options.max_hosts,
            })
        end)
        if not ok or not fetched then
            local err = (type(fetched) == "string" and fetched) or "正文（含段评气泡）获取失败"
            reportFailure("counts content failed", err)
            return nil, tostring(err)
        end
        content = fetched
    end

    local counts = ParaComments.countsFromContent(content)
    counts_cache[key] = { counts = counts }
    -- 走到这里说明正文（含气泡）已经拿到了：即便 counts 是空表，那也是一条
    -- 可信的「本章确认无评论」，按 12 小时档落盘。
    writeCountsFile(path, counts)
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

--[[--
v6 /api/comment 的统一评论解析。

响应 data.items[*] 字段（实测 2026-11-19）：
  id, content, user_name, avatar, likes, time(unix 秒), score,
  is_author, is_hot, is_vip, para_text, quote, location,
  replies, replies_next, replies_has_more, reply_list, segments, badges, images
segments 是 [{type="text"|"emoji"|"image", text/url/label...}]，纯文字阅读器
只用 content 串即可（含 [表情] 之类的 token，由 Leko/Emoticon 解码）。
]]--
local function parseV6Comments(payload)
    local list = {}
    local data = payload and type(payload.data) == "table" and payload.data or nil
    if not data then return list, "" end
    for _, item in ipairs(type(data.items) == "table" and data.items or {}) do
        if type(item) == "table" then
            local body = trim(text(item.content))
            if body ~= "" then
                local name = trim(text(item.user_name))
                list[#list + 1] = {
                    name = name ~= "" and name or "匿名",
                    text = body,
                    likes = tonumber(item.likes) or 0,
                    author = item.is_author == true,
                    timestamp = tonumber(item.time) or 0,
                }
            end
        end
    end
    -- 引文：优先 quote，其次 para_text（都来自响应，用于对齐校验/展示）。
    local para_text = sanitizeParaText(data.quote)
    if para_text == "" then para_text = sanitizeParaText(data.para_text) end
    return list, para_text
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

没有分页（2026-11-07 重测确认）：`action=paragraph_more` 无论怎么传
next_id / hot / chapter_md5 / page 都恒定回 44010102「请求参数错误」，且
`paragraph_first` 响应里全量扫描也没有任何 next/cursor 字段 —— 网页端的
「加载更多」按钮因拿不到 next_id 而永远不显示。所以七猫是「一次给全」，
首屏即全部。QQ 不同，它走毫秒时间戳游标续拉（见 platformSingleShot）。
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
书旗（sq）的段评不在 `tab=paras` 里。

实测（2026-11-20，《赤心巡天》book_id=9162887 item=2557729）：
  · `tab=paras` 无论给段号还是段落指纹，恒定 `items=[]`；
  · `tab=chapter` 有数据，条目自带 `quote`（该评论针对的原文）—— 整章评论与
    段评混在同一个列表里：quote 是本段正文的才是段评，quote 是章节标题的
    是章评；
  · 翻页参数是 **`cursor`**（`offset` 被忽略，next 恒为 "20"，会一直返回同一页）。

于是这里退化成「拉章节评论列表 → 用 quote 对齐本地段落」。翻页限量
SQ_MAX_PAGES 页，避免为了一段评论把整章列表翻到底。

代价说清楚：目标段的评论如果在热门前 N 条之外，这里拿不到；短引文（少于一
定位阈值）一律不做包含匹配，宁缺勿错。
]]--
local SQ_MAX_PAGES = 3

local function sqQuoteMatches(quote, paragraph, paragraphs)
    if quote == "" or paragraph == "" then return false end
    if quote == paragraph then return true end
    if not paragraph:find(quote, 1, true) then return false end
    if Util.utf8Length(quote) >= 6 then return true end
    -- 短引文（「其人」这种）：只有全章**唯一**一个段落包含它才敢认，
    -- 否则同一句在别处出现就会把评论挂错段。
    local hits = 0
    for _, candidate in ipairs(paragraphs) do
        if candidate:find(quote, 1, true) then
            hits = hits + 1
            if hits > 1 then return false end
        end
    end
    return hits == 1
end

local function fetchSqComments(platform, book_id, chapter_id, pid, source, paragraphs)
    local target = type(paragraphs) == "table" and paragraphs[(tonumber(pid) or 0) + 1] or ""
    if target == "" then return nil, nil, "缺少这一段正文，无法匹配书旗段评" end
    local validate = function(value)
        local data = value and value.data
        return type(data) == "table" and type(data.items) == "table"
    end
    local collected = {}
    local cursor = 0
    for _ = 1, SQ_MAX_PAGES do
        local query = "/api/comment?source=" .. percent_encode(platform.source_name or "书旗")
            .. "&tab=chapter"
            .. "&book_id=" .. percent_encode(book_id)
            .. "&item_id=" .. percent_encode(chapter_id)
            .. "&cursor=" .. intText(cursor)
            .. "&count=" .. intText(ParaComments.PAGE_SIZE)
            .. "&sort=hot"
        local payload, err = requestJson(source, query, validate)
        if not payload then
            if #collected == 0 then return nil, nil, err end
            break
        end
        local items = (payload.data or {}).items or {}
        for _, item in ipairs(items) do
            if type(item) == "table" then
                local body = trim(text(item.content))
                local quote = trim(text(item.quote))
                if quote == "" then quote = trim(text(item.para_text)) end
                if body ~= "" and sqQuoteMatches(quote, target, paragraphs) then
                    local name = trim(text(item.user_name))
                    collected[#collected + 1] = {
                        name = name ~= "" and name or "匿名",
                        text = body,
                        likes = tonumber(item.likes) or 0,
                        author = item.is_author == true,
                        timestamp = tonumber(item.time) or 0,
                    }
                end
            end
        end
        local next_cursor = tonumber((payload.data or {}).next)
        if not next_cursor or next_cursor <= cursor or #items == 0 then break end
        cursor = next_cursor
    end
    return collected, target
end

--[[--
v6：按平台拉一页评论。返回 list, para_text, next_cursor, has_more, err。

统一走 /api/comment（Bearer JWT），source 用中文源名，para 用 0 基段号，
offset 分页。next_cursor 语义变为「下一页 offset」。
]]--
local function fetchCommentPage(platform, book_id, chapter_id, pid, start, source, paragraphs)
    local source_name = platform.source_name or source or "番茄小说"
    --[[--
    定位这一段用哪个值。

    番茄 / QQ 用段号（QQ 的 1 基偏移由 toBackendPid 换算）。**七猫例外**：
    v6 的 `para` 仍然收「段落内容指纹」（md5(去首尾空白)[:8]），不是段号 ——
    实测 2026-11-20，《剑来》book_id=143170 item=36898237，para=0/1/2 恒定
    total=0，换成对应段落的指纹后同一段分别回 16327 / 1363 / 652 条。
    所以七猫必须拿本地段落现算指纹（子进程 fork 下来带着 paragraphs）。
    ]]--
    local para_value
    if platform.para_mode == "fingerprint" then
        local body = type(paragraphs) == "table"
            and paragraphs[(tonumber(pid) or 0) + 1] or nil
        para_value = body and ParaComments.qmFingerprint(body) or ""
        if para_value == "" then
            return nil, nil, nil, nil, "缺少这一段正文，无法定位七猫段评"
        end
    else
        para_value = toBackendPid(platform, pid)
    end
    local query = "/api/comment?source=" .. percent_encode(source_name)
        .. "&tab=paras"
        .. "&book_id=" .. percent_encode(book_id)
        .. "&item_id=" .. percent_encode(chapter_id)
        .. "&para=" .. para_value
        .. "&offset=" .. intText(start)
        .. "&count=" .. intText(ParaComments.PAGE_SIZE)
        .. "&sort=hot"
    local validate = function(value)
        local data = value and value.data
        return type(data) == "table" and type(data.items) == "table"
    end
    local payload, err = requestJson(source, query, validate)
    if not payload then
        reportFailure("comments request failed", err)
        return nil, nil, nil, nil, err
    end
    local list, para_text = parseV6Comments(payload)
    local data = payload.data or {}
    local next_cursor = tonumber(data.next)
    if not next_cursor or next_cursor < 0 then next_cursor = start + #list end
    next_cursor = math.floor(next_cursor)
    local has_more = data.has_more == true
    -- 服务端没给 has_more 时按「满一页就还可能有余量」推断；空页到此为止。
    if data.has_more == nil then has_more = #list >= ParaComments.PAGE_SIZE end
    if not has_more or next_cursor == (tonumber(start) or 0) then
        has_more = false
    end
    return list, para_text, next_cursor, has_more, nil
end

--[[--
取某一段的评论正文。

options.cursor
    续拉提示（= 上次拿到的 page.next_cursor）。只在「本地这批已经覆盖到那里」
    时才从该位置续拉，否则从本地这批的尾部接着拉，绝不交出中间缺条的列表。
    省略表示「首次打开这一段」：缓存有效就直接用缓存，不打网络。
    值的语义按平台：番茄是条数偏移，QQ 是毫秒时间戳，七猫不用。
options.force
    true 时忽略磁盘缓存，重新从开头拉。
options.paragraphs
    model.paragraphs。**七猫必需**：它按段落内容指纹定位，要拿本地段落现算指纹
    （见 qmFingerprint）；番茄 / QQ 用不上（它们的 pid 是段号，基准差在
    fetchCommentPage 里由 toBackendPid 换算）。

`pid` 一律是**内部 0 基段号**（与 ensureCounts 的键同一套坐标），
后端基准的差异不会漏给调用方。

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
        return nil, nil, "该章节所在平台没有段评（目前支持番茄 / QQ阅读 / 七猫 / 书旗 / 半夏）"
    end

    local host = ParaComments.host(source)
    local key = commentsKey(book, chapter_index, host, pid)

    local cached
    if not options.force then
        cached = readDiskCache(key, ParaComments.COMMENTS_TTL)
    end
    if cached and type(cached.list) ~= "table" then cached = nil end
    -- v6 换了接口/解析/游标语义，所有平台的旧缓存都必须丢弃重拉。
    if cached and cached.cache_version ~= COMMENTS_CACHE_VERSION then cached = nil end

    -- 调用方带了 cursor = 这是「继续加载」，不能拿缓存快照糊弄它。
    local caller_continues = tonumber(options.cursor) ~= nil
    -- 七猫一次给全：一律走缓存，照着 cursor 再拉一次只会把同一批评论在尾部
    -- 追加一遍。能续拉的平台（番茄 / QQ）则是「没带 cursor 就吃缓存」
    -- （TTL 6h，翻回同一段不必再打后端），带了 cursor 才真的去拉下一页。
    local single_shot = platformSingleShot(platform)
    if cached and (not caller_continues or single_shot) then
        return cached.list, cached.para_text, nil, pageInfo(cached, platform)
    end

    -- 书旗走另一条路：段评混在 tab=chapter 列表里，用 quote 标段落（详见
    -- fetchSqComments）。它一次就把能匹配的都给全，没有 offset 续拉。
    if platform.code == "sq" then
        local list, para_text, err = fetchSqComments(platform, book_id, chapter_id, pid, source,
            options.paragraphs)
        if not list then return nil, nil, err end
        local record = {
            list = list,
            para_text = tostring(para_text or ""),
            next_cursor = #list,
            has_more = false,
            cache_version = COMMENTS_CACHE_VERSION,
        }
        if #list > 0 then writeDiskCache(key, record) end
        return record.list, record.para_text, nil, pageInfo(record, platform)
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
    -- QQ 的续拉点是毫秒时间戳而非 0，这里同样只会取 1 页。
    -- 七猫一次给全，本来就只该请求 1 次 —— 第二页拿回来的是同一批。
    local page_budget = (start == 0) and ParaComments.FIRST_OPEN_PAGES or 1
    if single_shot then page_budget = 1 end

    local collected, para_text = {}, nil
    local next_cursor, has_more = start, false
    local extra_error = nil
    for page_index = 1, page_budget do
        local page_list, page_text, page_next, page_more, page_err =
            fetchCommentPage(platform, book_id, chapter_id, pid, next_cursor, source, options.paragraphs)
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
    -- 空页 + 已知无 paras 通道的平台：标记出来，让 UI 说清楚原因（见
    -- PARAS_EMPTY_PLATFORMS）。有数据时一律不标记 —— 别把偶发的单段空页
    -- 误判成平台不支持。
    cached.unsupported = (#cached.list == 0)
        and (ParaComments.PARAS_EMPTY_PLATFORMS[platform.code] == true) or false
    cached.cache_version = COMMENTS_CACHE_VERSION
    -- 一条都没取到就别写缓存：大概率是服务端抽风（实测出现过整个请求被拒），
    -- 写进去只会让读者在 TTL 内一直看到空。**例外**：已知平台压根没有 paras
    -- 通道（sq / qm），那空就是稳定事实，缓存 6h 免得读者每点一段都白等一次。
    if #cached.list > 0 or cached.unsupported then
        writeDiskCache(key, cached)
    end
    return cached.list, cached.para_text, nil, pageInfo(cached, platform)
end

return ParaComments
