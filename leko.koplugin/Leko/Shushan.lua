-- Native (pure-Lua) driver for the 书山聚合 backend.
--
-- The upstream Legado source performs login, node selection, search, catalog
-- and chapter retrieval inside several megabytes of obfuscated JavaScript.
-- Running that on a Kindle/Kobo through the QuickJS bridge was the single
-- point of failure: no WebView for the login H5, evaluation timeouts on the
-- packed jsLib, and a 6 MB realm budget.  Everything that source did can be
-- expressed as six HTTP calls, so this module does exactly that in Lua.
--
-- Integration: `Leko/BuiltinSources.lua` owns the local `leko://shushan/...`
-- URL scheme.  Requests for those URLs never touch the network layer of the
-- rule engine; they are served from here (see LegadoSource:request ->
-- BuiltinSources:request).  The rules bound to the source are plain JSONPath
-- selectors over the JSON this module returns, plus one HTML selector for the
-- chapter body.
--
-- Security posture: credentials are supplied by the user (邮箱 / 密码 /
-- 设备ID) through the regular 书源配置 screen and are stored in the source's
-- runtime file.  The device id is never generated here - the backend treats a
-- forged id as abuse.

local rapidjson = require("rapidjson")
local logger = require("logger")

local Util = require("Leko/Util")
local Http = require("Leko/Http")

local Shushan = {}

Shushan.PREFIX = "leko://shushan"

-- Fixed protocol constants taken from the v5.53 book source itself.
Shushan.NOVEL_TOKEN = "SHUSAN_READ_2025"
Shushan.USER_AGENT = "Mozilla/5.0 (Linux; Android 14; 23127PN0CC) "
    .. "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
Shushan.CONTENT_VERSION = "12"

-- The aggregate runs the same service behind several mirrors.  They are NOT
-- interchangeable per endpoint: v1's /search upstream was dead while v2-v4
-- answered normally, so the node list is walked per request instead of being
-- pinned once at build time.
Shushan.HOSTS = {
    "https://v1.vossc.com",
    "https://v2.vossc.com",
    "https://v3.vossc.com",
    "https://v4.vossc.com",
    "http://1.94.248.5:7001",
    "http://113.44.163.166:7001",
}

Shushan.REQUEST_TIMEOUT = 20
Shushan.MAX_BYTES = 4 * 1024 * 1024

-- SourceHealth asks for a health probe inside a forked worker that
-- AsyncSourceProbe kills after SOURCE_DEADLINE (7s).  The full six-mirror walk
-- used by the 检测节点 button cannot fit in that budget, so the probe gets an
-- explicit wall-clock allowance instead of relying on per-request timeouts to
-- add up favourably.  Keep PROBE_BUDGET comfortably below 7.
Shushan.PROBE_BUDGET = 5
Shushan.PROBE_HOSTS = 2
Shushan.PROBE_TIMEOUT = 3

-- loginUi field names, also used as the storage keys inside source.login_info.
Shushan.FIELD_EMAIL = "邮箱"
Shushan.FIELD_PASSWORD = "密码"
Shushan.FIELD_DEVICE = "设备ID"
-- Internal runtime keys (not declared in loginUi, so the UI never shows them).
Shushan.KEY_API = "_api_key"
Shushan.KEY_HOST = "_host"

-- The rule engine derives a book's identity from its URL
-- (`book_id = "net-" .. hashId(source_id .. "\n" .. book_url)`), so this
-- payload must only ever carry fields that do not drift over time.  `wordCount`
-- and `latestChapterTitle` are deliberately absent: they change whenever the
-- book is updated, and including them would mint a new book id on every update
-- (duplicate shelf entries, lost reading progress).  They are not needed here
-- anyway - `ruleSearch` reads them straight off the search response.
local DETAIL_FIELDS = {
    "source", "url", "name", "tab", "author", "cover", "intro", "kind",
}
local CHAPTER_FIELDS = { "source", "cid", "bookid", "itemid", "url", "name", "title", "chapterid", "curl" }

local AUTH_ERROR_NEEDLES = {
    "缺少登录凭证", "访问被拒绝", "未登录", "登录已过期", "凭证无效",
}
local NODE_ERROR_NEEDLES = {
    "服务暂时不可用", "服务不可用", "请尝试切换服务器",
}

local function text(value)
    return tostring(value == nil and "" or value)
end

local function trim(value)
    return Util.trim(text(value))
end

-- Detail/chapter descriptors are newline-joined and base64 encoded.  Newlines
-- cannot appear inside a value, and the field order is fixed, so the encoded
-- string is byte-identical for the same book - which matters because leko
-- derives the book id from a hash of the book URL.
local function strip_newlines(value)
    return (text(value):gsub("[%c]+", " "))
end

local function storage()
    return require("Leko/Storage")
end

-- Wall-clock helper shared by the node check and the health probe.  socket is
-- optional (some builds answer without it), and os.time is only a 1s fallback.
local function now_seconds()
    local ok, socket = pcall(require, "socket")
    if ok and socket and type(socket.gettime) == "function" then
        local fine, value = pcall(socket.gettime)
        if fine and value then return value end
    end
    return os.time()
end

local function crypto()
    return require("Leko/CryptoCompat")
end

local function base64_encode(value)
    local ok, encoded = pcall(function() return crypto().base64Encode(text(value)) end)
    return ok and text(encoded) or ""
end

local function base64_decode(value)
    local ok, decoded = pcall(function() return crypto().base64Decode(text(value)) end)
    return ok and decoded and tostring(decoded) or nil
end

local function percent_encode(value)
    return (text(value):gsub("[^A-Za-z0-9%-%._~]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

-- The catalog sends ids as JSON numbers, so `tostring` may render them as
-- "1.0" (float) depending on the VM.  Those ids travel back to the server
-- inside the request body, so normalise them to plain integers first.
local function int_text(value)
    local number = tonumber(value)
    if not number then return trim(value) end
    return string.format("%d", math.floor(number))
end

local function decode_json(body)
    local ok, value = pcall(rapidjson.decode, text(body))
    if ok and type(value) == "table" then return value end
    return nil
end

local function contains_any(message, needles)
    message = text(message)
    if message == "" then return false end
    for index = 1, #needles do
        if message:find(needles[index], 1, true) then return true end
    end
    return false
end

local function pack_fields(fields, values)
    local parts = {}
    for index = 1, #fields do parts[index] = strip_newlines(values[fields[index]]) end
    return table.concat(parts, "\n")
end

local function unpack_fields(fields, raw)
    local values, index = {}, 1
    local decoded = base64_decode(raw)
    if not decoded then return nil end
    local position = 1
    while index <= #fields do
        local stop = decoded:find("\n", position, true)
        if stop then
            values[fields[index]] = decoded:sub(position, stop - 1)
            position = stop + 1
        else
            values[fields[index]] = decoded:sub(position)
            position = #decoded + 1
        end
        index = index + 1
    end
    return values
end

local function escape_html(value)
    return (text(value):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

function Shushan:loginInfo(source)
    local info = type(source) == "table" and source.login_info or nil
    if type(info) ~= "table" then return {} end
    return info
end

function Shushan:credentials(source)
    local info = self:loginInfo(source)
    return {
        email = trim(info[self.FIELD_EMAIL]),
        password = trim(info[self.FIELD_PASSWORD]),
        device_id = trim(info[self.FIELD_DEVICE]):lower(),
        api_key = trim(info[self.KEY_API]),
        host = trim(info[self.KEY_HOST]),
    }
end

-- Credentials are stored in source.login_info, which lives in the source's
-- runtime file (sources/runtime/<id>.lua).  Re-importing or re-seeding the
-- source replaces only the rule body, so this survives book-source updates.
function Shushan:setLoginInfo(source, patch)
    if type(source) ~= "table" then return false end
    if type(source.login_info) ~= "table" then source.login_info = {} end
    for key, value in pairs(patch or {}) do source.login_info[key] = value end
    -- Storage:saveSourceRuntime is declared with `:` so it needs an explicit
    -- self; a dot call would silently pass the source as self and then bail
    -- out with "source.id is required", losing the api key on restart.
    local ok, saved = pcall(function() return storage():saveSourceRuntime(source) end)
    if not ok then return false end
    return saved ~= false
end

function Shushan:hostLabel(host)
    local label = text(host):gsub("^https?://", "")
    return label:gsub("/+$", "")
end

function Shushan:mask(value)
    local value_text = text(value)
    if #value_text <= 6 then return value_text == "" and "(空)" or "****" end
    return value_text:sub(1, 3) .. string.rep("*", #value_text - 6) .. value_text:sub(-3)
end

-- Preferred node first (runtime memory, then this process), then everything
-- else.  A node that answers is remembered; a node that fails is simply
-- skipped for the rest of the request.
function Shushan:hostOrder(source)
    local order, seen = {}, {}
    local preferred = self:credentials(source).host
    if preferred == "" then preferred = text(self._preferred) end
    local function push(host)
        host = text(host):gsub("/+$", "")
        if host ~= "" and not seen[host] then
            seen[host] = true
            order[#order + 1] = host
        end
    end
    push(preferred)
    for index = 1, #self.HOSTS do push(self.HOSTS[index]) end
    return order
end

function Shushan:_rememberHost(source, host)
    host = text(host):gsub("/+$", "")
    if host == "" then return end
    local previous = text(self._preferred)
    self._preferred = host
    if previous ~= host then
        logger.info(string.format("[LekoShushan] node selected: %s", self:hostLabel(host)))
    end
    if self:credentials(source).host ~= host then
        self:setLoginInfo(source, { [self.KEY_HOST] = host })
    end
end

-- ---------------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------------

function Shushan:baseHeaders(api_key)
    local headers = {
        ["User-Agent"] = self.USER_AGENT,
        ["X-Novel-Token"] = self.NOVEL_TOKEN,
    }
    api_key = trim(api_key)
    if api_key ~= "" then headers["X-Api-Key"] = base64_encode(api_key) end
    return headers
end

function Shushan:fetch(options)
    local response, err = Http:request({
        url = options.url,
        method = options.method or "GET",
        headers = options.headers or {},
        body = options.body or "",
        timeout = options.timeout or self.REQUEST_TIMEOUT,
        maxtime = options.maxtime or (self.REQUEST_TIMEOUT * 3),
        retries = 0,
        max_bytes = self.MAX_BYTES,
        accept = "application/json,text/html;q=0.9,*/*;q=0.8",
    })
    if not response then return nil, text(err or "网络请求失败") end
    return response
end

-- Walks the node list until `validate` accepts a payload.
--   spec(host, headers) -> url, method, body, extra_headers
-- Auth failures trigger exactly one re-login and a single retry on the same
-- node; 4xx answers abort the walk because another mirror cannot fix a bad
-- request.  Business-level "this mirror produced nothing" answers do continue.
function Shushan:requestJson(source, spec, validate, options)
    options = options or {}
    local api_key = options.api_key or self:apiKey(source)
    local hosts = self:hostOrder(source)
    local limit = tonumber(options.max_hosts) or #hosts
    local errors, tried, refreshed = {}, 0, false

    for index = 1, #hosts do
        if tried >= limit then break end
        local host = hosts[index]
        tried = tried + 1
        local headers = self:baseHeaders(api_key)
        local url, method, body, extra = spec(host, headers)
        if type(extra) == "table" then
            for key, value in pairs(extra) do headers[key] = value end
        end

        local response, err = self:fetch({
            url = url, method = method, headers = headers, body = body,
            timeout = options.timeout,
        })

        if response and tonumber(response.code) == 200 then
            local payload = decode_json(response.body)
            if not payload then
                errors[#errors + 1] = self:hostLabel(host) .. "：响应不是 JSON"
            else
                local message = payload.error or payload.message or payload.msg
                if contains_any(message, AUTH_ERROR_NEEDLES) and not refreshed then
                    refreshed = true
                    api_key = self:apiKey(source, { force = true })
                    if trim(api_key) ~= "" then
                        payload, response = self:retryOnce(source, spec, host, api_key, options)
                    end
                end
                if payload and (not validate or validate(payload)) then
                    self:_rememberHost(source, host)
                    return payload, host
                end
                errors[#errors + 1] = self:hostLabel(host) .. "："
                    .. (trim(message) ~= "" and trim(message) or "没有返回数据")
            end
        elseif response then
            local code = tonumber(response.code) or 0
            -- The aggregate abuses 201/403-style codes to carry a human
            -- readable business reason (VIP-locked, region blocked, ...).
            -- Surface it instead of a bare "HTTP 201": every mirror will
            -- answer the same for this book, so also stop walking the pool.
            local reason = ""
            local body_json = decode_json(response.body)
            local body_text = ""
            if type(body_json) == "table" then
                body_text = text(body_json.error or body_json.message or body_json.msg)
            elseif type(response.body) == "string" then
                body_text = trim(response.body)
            end
            if trim(body_text) ~= "" and #body_text <= 200 then
                reason = trim(body_text)
            end
            if reason ~= "" then
                errors[#errors + 1] = self:hostLabel(host) .. "：" .. reason
                if contains_any(reason, { "VIP", "会员", "付费", "版权", "授权" }) then break end
            else
                errors[#errors + 1] = self:hostLabel(host) .. "：HTTP " .. text(code)
            end
            if code >= 400 and code < 500 then break end
        else
            errors[#errors + 1] = self:hostLabel(host) .. "：" .. text(err)
        end
    end

    return nil, table.concat(errors, "\n")
end

function Shushan:retryOnce(source, spec, host, api_key, options)
    local headers = self:baseHeaders(api_key)
    local url, method, body, extra = spec(host, headers)
    if type(extra) == "table" then
        for key, value in pairs(extra) do headers[key] = value end
    end
    local response = self:fetch({
        url = url, method = method, headers = headers, body = body,
        timeout = options and options.timeout,
    })
    if not response or tonumber(response.code) ~= 200 then return nil, response end
    return decode_json(response.body), response
end

-- ---------------------------------------------------------------------------
-- Endpoints
-- ---------------------------------------------------------------------------

function Shushan:login(source, options)
    options = options or {}
    local credentials = self:credentials(source)
    if credentials.email == "" or credentials.password == "" then
        return false, "请先填写邮箱和密码：\n书源 → 书山聚合（原生）→ 配置书源"
    end

    local hosts = self:hostOrder(source)
    local limit = math.min(#hosts, tonumber(options.max_hosts) or 3)
    local errors = {}

    for index = 1, limit do
        local host = hosts[index]
        local response, err = self:fetch({
            url = host .. "/login",
            method = "POST",
            headers = {
                ["User-Agent"] = self.USER_AGENT,
                ["Content-Type"] = "application/x-www-form-urlencoded",
            },
            body = "email=" .. percent_encode(credentials.email)
                .. "&password=" .. percent_encode(credentials.password),
            timeout = 15,
        })
        if not response then
            errors[#errors + 1] = self:hostLabel(host) .. "：" .. text(err)
        else
            local payload = decode_json(response.body)
            local data = payload and payload.data
            local user = type(data) == "table" and data.user or nil
            local api_key = type(user) == "table" and trim(user.api_key) or ""
            if payload and tonumber(payload.code) == 200 and api_key ~= "" then
                local device = type(data) == "table" and type(data.device) == "table"
                    and data.device or {}
                self._preferred = host
                self:setLoginInfo(source, {
                    [self.KEY_API] = api_key,
                    [self.KEY_HOST] = host,
                })
                return true, string.format(
                    "登录成功\n节点：%s\n密钥：%s\n设备：%s/%s",
                    self:hostLabel(host), self:mask(api_key),
                    text(device.online_count or 0), text(device.device_limit or 0))
            end
            local message = payload and (payload.message or payload.error or payload.msg)
            errors[#errors + 1] = self:hostLabel(host) .. "："
                .. (trim(message) ~= "" and trim(message) or ("HTTP " .. text(response.code)))
            -- Credential problems look the same on every mirror, so stop after
            -- the first one instead of walking the whole pool.
            if contains_any(message, { "密码", "邮箱", "账号", "未注册", "封禁" }) then break end
        end
    end

    return false, "登录失败\n" .. table.concat(errors, "\n")
end

function Shushan:apiKey(source, options)
    options = options or {}
    local credentials = self:credentials(source)
    if credentials.api_key ~= "" and not options.force then return credentials.api_key end
    if credentials.email == "" or credentials.password == "" then return "" end
    local ok = self:login(source, { force = options.force })
    if not ok then return "" end
    return self:credentials(source).api_key
end

function Shushan:search(source, keyword, page)
    keyword = trim(keyword)
    page = tonumber(page) or 1
    if keyword == "" then return nil, "请输入搜索关键词" end

    local query = "/search?login=search&key=" .. percent_encode(keyword)
        .. "&page=" .. tostring(page) .. "&source="
    local payload, host_or_err = self:requestJson(source,
        function(host) return host .. query end,
        function(value)
            return type(value.data) == "table" and #value.data > 0
        end)

    if not payload then return nil, host_or_err end

    local results = {}
    for _, item in ipairs(payload.data or {}) do
        if type(item) == "table" then
            local title = trim(item.title)
            if title ~= "" then
                local detail = pack_fields(DETAIL_FIELDS, {
                    source = item.source, url = item.book_url, name = title,
                    tab = item.tab, author = item.author, cover = item.cover,
                    intro = item.desc, kind = item.tags,
                })
                local latest = trim(item.latestChapterTitle)
                -- 聚合源：结果行要能看出底层站点（番茄/QQ阅读/七猫……）。
                -- 同时只保留小说 tab，漫画/短剧等其它 tab 一律不进结果。
                local tab = trim(item.tab)
                if tab ~= "" and tab ~= "novel" then
                    -- 非小说 tab（漫画/短剧等）不进搜索结果
                else
                    results[#results + 1] = {
                        name = title,
                        author = trim(item.author),
                        intro = trim(item.desc),
                        cover = trim(item.cover),
                        kind = trim(item.tags),
                        wordCount = trim(item.wordCount),
                        lastChapter = latest ~= "" and latest or "",
                        origin = trim(item.source),
                        source = trim(item.source),
                        bookUrl = self.PREFIX .. "/book?d=" .. base64_encode(detail),
                    }
                end
            end
        end
    end

    if #results == 0 then
        return nil, "该书源没有返回结果\n可到「配置书源」里点『检测节点』换一台镜像"
    end
    return { results = results }
end

-- One catalog call serves both the book-info step (to hand back a tocUrl) and
-- the toc step itself, because book info and toc run in different forked
-- workers and cannot share an in-process cache.
function Shushan:requestCatalog(source, detail)
    if trim(detail.url) == "" then return nil, "书源没有返回书籍地址" end
    local body = rapidjson.encode({
        source = trim(detail.source),
        url = trim(detail.url),
        name = trim(detail.name),
        bookid = trim(detail.bookid),
        tab = trim(detail.tab) ~= "" and trim(detail.tab) or "novel",
    })
    local payload, host_or_err = self:requestJson(source,
        function(host)
            return host .. "/catalog", "POST", body,
                { ["Content-Type"] = "application/json" }
        end,
        function(value)
            return type(value.data) == "table" and #value.data > 0
        end,
        { timeout = 30, max_hosts = 4 })
    if not payload then return nil, host_or_err end
    return payload
end

function Shushan:book(source, detail)
    local payload, err = self:requestCatalog(source, detail)
    if not payload then return nil, err end
    return {
        name = trim(detail.name),
        author = trim(detail.author),
        intro = trim(detail.intro),
        cover = trim(detail.cover),
        kind = trim(detail.kind),
        tocUrl = self.PREFIX .. "/toc?d=" .. base64_encode(pack_fields(DETAIL_FIELDS, detail)),
    }
end

function Shushan:toc(source, detail)
    local payload, err = self:requestCatalog(source, detail)
    if not payload then return nil, err end

    local source_name = trim(detail.source)
    local book_name = trim(detail.name)
    local book_url = trim(detail.url)
    -- The aggregate's /catalog does NOT return per-chapter request urls for
    -- most sources; the legado source builds them client-side
    -- (buildChapterUrl).  Replicate that here: the fields we pack determine
    -- what chapter() will POST to /content.
    local fanqie = source_name:find("番茄", 1, true) ~= nil
    local bookid = book_url:match("book_id=(%d+)") or book_url:match("bookid=(%d+)") or ""
    local chapters = {}
    for _, item in ipairs(payload.data or {}) do
        if type(item) == "table" and item.isVolume ~= true then
            local chapter_url = trim(item.url)
            local fields = {
                source = source_name,
                cid = int_text(item.cid),
                bookid = bookid,
                itemid = "",
                url = book_url,
                name = book_name,
                title = trim(item.title),
                chapterid = "",
                curl = chapter_url,
            }
            if fanqie then
                fields.itemid = chapter_url:match("item_id=(%d+)") or ""
                fields.bookid = fields.bookid ~= "" and fields.bookid
                    or chapter_url:match("book_id=(%d+)") or ""
            else
                fields.bookid = chapter_url:match("book_id=(%d+)") or chapter_url:match("bookid=(%d+)") or bookid
                fields.chapterid = chapter_url:match("chapterid=(%d+)") or chapter_url:match("chapterId=(%d+)") or ""
            end
            local encoded = pack_fields(CHAPTER_FIELDS, fields)
            chapters[#chapters + 1] = {
                title = trim(item.title),
                url = self.PREFIX .. "/chapter?d=" .. base64_encode(encoded),
            }
        end
    end

    if #chapters == 0 then return nil, "该书目录为空" end
    return { chapters = chapters, bookid = bookid }
end

-- The chapter body is plain UTF-8 text served by the aggregate; the only
-- requirement is a registered device id in X-Device-Id plus a supported
-- protocol version.
function Shushan:chapter(source, chapter)
    local credentials = self:credentials(source)
    if credentials.device_id == "" then
        return nil, "缺少设备ID\n请到「书源 → 书山聚合（原生）→ 配置书源」填写一本机已登记的设备ID"
    end

    local source_name = trim(chapter.source)
    -- Mirror the legado source's content request body exactly:
    -- {cid, source, version} + per-source fields.  Extra/missing fields are
    -- what caused 503 "版本不受支持" and empty-catalog failures before.
    local body = {
        cid = math.floor(tonumber(chapter.cid) or 0),
        source = source_name,
        version = self.CONTENT_VERSION,
    }
    local fanqie = source_name:find("番茄", 1, true) ~= nil
    if fanqie then
        body.book_id = trim(chapter.bookid)
        if trim(chapter.itemid) ~= "" then body.item_id = trim(chapter.itemid) end
    else
        -- For non-fanqie sources the aggregate expects the BOOK's catalog url,
        -- not a per-chapter url.
        body.url = trim(chapter.url)
        if trim(chapter.bookid) ~= "" and trim(chapter.chapterid) ~= "" then
            body.bookid = trim(chapter.bookid)
            body.chapterid = trim(chapter.chapterid)
        end
        if trim(chapter.curl) ~= "" and source_name == "七猫小说" then
            body.qm_url = trim(chapter.curl)
        end
    end

    local encoded = rapidjson.encode(body)
    local payload, host_or_err = self:requestJson(source,
        function(host)
            return host .. "/content", "POST", encoded, {
                ["Content-Type"] = "application/json",
                ["X-Device-Type"] = "android",
                ["X-Device-Id"] = credentials.device_id,
            }
        end,
        function(value)
            local data = value.data
            local content = type(data) == "table" and text(data.content) or ""
            if content == "" then return false end
            -- A mirror can answer 200 with a human-readable outage notice.
            if contains_any(content, NODE_ERROR_NEEDLES) then return false end
            if contains_any(content, { "设备标识缺失", "设备码无效", "版本不受支持", "版本无效" }) then
                return true
            end
            return true
        end,
        { timeout = 30, max_hosts = 3 })

    if not payload then
        local detail = text(host_or_err)
        local hint
        if contains_any(detail, { "VIP", "会员专享", "付费" }) then
            hint = "这本书在书山是 VIP 专享，本源读不了。\n可回到搜索结果选同一本书的其他站点版本（如番茄小说）"
        else
            hint = "可到「配置书源」里点『检测节点』换一台镜像"
        end
        return nil, "取正文失败\n" .. detail .. "\n" .. hint
    end

    local data = type(payload.data) == "table" and payload.data or {}
    local content = text(data.content)
    -- The legado source base64-decodes content whenever it looks encoded.
    if content ~= "" and content:match("^[A-Za-z0-9+/]+={0,2}$") then
        local decoded = base64_decode(content)
        if decoded ~= "" and not decoded:match("^%s*$") then content = decoded end
    end
    if contains_any(content, { "设备标识缺失", "设备码无效" }) then
        return nil, content .. "\n请到「配置书源」核对设备ID"
    end
    if contains_any(content, { "版本不受支持", "版本无效" }) then
        return nil, content .. "\n（书山后端已升级协议版本）"
    end
    return content
end

-- ---------------------------------------------------------------------------
-- Response assembly for the rule engine
-- ---------------------------------------------------------------------------

function Shushan:response(body, content_type)
    return {
        url = self.PREFIX,
        code = 200,
        headers = { ["content-type"] = content_type },
        content_type = content_type,
        body = text(body),
        status = "200 OK",
    }
end

function Shushan:jsonResponse(value)
    return self:response(rapidjson.encode(value), "application/json; charset=utf-8")
end

function Shushan:contentHtml(content)
    local plain = text(content)
    if plain:find("<", 1, true) then plain = Util.stripHtml(plain) end
    local paragraphs = {}
    for line in (plain .. "\n"):gmatch("([^\n]*)\n") do
        line = trim(line)
        if line ~= "" then paragraphs[#paragraphs + 1] = "<p>" .. escape_html(line) .. "</p>" end
    end
    if #paragraphs == 0 then paragraphs[1] = "<p>（本章暂无正文）</p>" end
    return '<article id="content">' .. table.concat(paragraphs) .. '</article>'
end

function Shushan:htmlResponse(message)
    return self:response(self:contentHtml(message), "text/html; charset=utf-8")
end

function Shushan:parseUrl(url)
    url = text(url)
    local action = url:match("^leko://shushan/([%w_]+)")
    if not action then return nil, {} end

    if action == "search" then
        -- The rules template renders `{{key}}` already percent-encoded.
        local keyword = url:match("[?&]key=([^&]*)") or ""
        keyword = keyword:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end)
        return action, {
            key = keyword,
            page = tonumber(url:match("[?&]page=(%d+)")) or 1,
        }
    end

    local raw = url:match("[?&]d=([^&]+)")
    if not raw then return action, {} end
    if action == "chapter" then return action, unpack_fields(CHAPTER_FIELDS, raw) or {} end
    return action, unpack_fields(DETAIL_FIELDS, raw) or {}
end

function Shushan:handle(url, source)
    local action, values = self:parseUrl(url)
    if action == "search" then
        local result, err = self:search(source, values.key, values.page)
        if not result then
            logger.warn("[LekoShushan] search failed: " .. text(err))
            return self:jsonResponse({ results = {}, error = text(err) })
        end
        return self:jsonResponse(result)
    elseif action == "book" then
        local result, err = self:book(source, values)
        if not result then
            logger.warn("[LekoShushan] book info failed: " .. text(err))
            return self:jsonResponse({ name = trim(values.name), error = text(err) })
        end
        return self:jsonResponse(result)
    elseif action == "toc" then
        local result, err = self:toc(source, values)
        if not result then
            logger.warn("[LekoShushan] toc failed: " .. text(err))
            return self:jsonResponse({ chapters = {}, error = text(err) })
        end
        return self:jsonResponse(result)
    elseif action == "chapter" then
        local content, err = self:chapter(source, values)
        if not content then
            logger.warn("[LekoShushan] chapter failed: " .. text(err))
            return self:htmlResponse(err)
        end
        return self:response(self:contentHtml(content), "text/html; charset=utf-8")
    end
    return self:htmlResponse("未知的书山请求：" .. text(url))
end

-- ---------------------------------------------------------------------------
-- loginUi buttons (executed natively, never through QuickJS)
-- ---------------------------------------------------------------------------

-- Both the 检测节点 button and the health probe must agree on what "this mirror
-- is alive" means, so the predicate lives in one place.  A 200 alone is not
-- enough: an unrelated server answers 200 for any path, and a mirror can be up
-- while its upstream is dead (observed on v1, whose /detection answers while
-- /search returns nothing).
function Shushan:detectionOk(response)
    if not response or tonumber(response.code) ~= 200 then return false end
    return text(response.body):find("书山", 1, true) ~= nil
end

function Shushan:checkNodes(source)
    local lines, best, best_ms = {}, nil, nil
    for index = 1, #self.HOSTS do
        local host = self.HOSTS[index]
        local started = now_seconds()
        local response = self:fetch({
            url = host .. "/detection",
            headers = { ["User-Agent"] = self.USER_AGENT },
            timeout = 8,
        })
        local elapsed = math.floor((now_seconds() - started) * 1000 + 0.5)
        local ok = self:detectionOk(response)
        if ok then
            lines[#lines + 1] = string.format("✅ %s  %d ms", self:hostLabel(host), elapsed)
            if not best_ms or elapsed < best_ms then
                best, best_ms = host, elapsed
            end
        else
            lines[#lines + 1] = string.format("❌ %s  %s", self:hostLabel(host),
                response and ("HTTP " .. text(response.code)) or "无响应")
        end
    end

    if best then
        self._preferred = best
        self:setLoginInfo(source, { [self.KEY_HOST] = best })
        lines[#lines + 1] = ""
        lines[#lines + 1] = "已选用：" .. self:hostLabel(best)
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = "所有节点都不通，检查网络后重试"
    end
    return best ~= nil, table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Health probe (called by Leko/SourceHealth:probe inside a forked worker)
-- ---------------------------------------------------------------------------

-- Reports whether any mirror answers /detection right now.
--
-- This is deliberately NOT checkNodes: it walks at most PROBE_HOSTS mirrors
-- within PROBE_BUDGET wall-clock seconds, and it never writes state.  The
-- probe worker runs in a separate process, so persisting the chosen node from
-- here would race the parent's own runtime cache.
function Shushan:probe(source, options)
    options = options or {}
    local budget = tonumber(options.budget) or self.PROBE_BUDGET
    local limit = math.min(#self:hostOrder(source), tonumber(options.max_hosts) or self.PROBE_HOSTS)
    local started = now_seconds()
    local errors = {}
    local first_target

    for index = 1, limit do
        local host = self:hostOrder(source)[index]
        local remaining = budget - (now_seconds() - started)
        if index > 1 and remaining <= 0.5 then
            errors[#errors + 1] = self:hostLabel(host) .. "：探测预算已用完"
            break
        end
        local target = host .. "/detection"
        first_target = first_target or target
        local timeout = math.max(1, math.min(self.PROBE_TIMEOUT, remaining))
        local request_started = now_seconds()
        local response = self:fetch({
            url = target,
            headers = { ["User-Agent"] = self.USER_AGENT },
            timeout = timeout,
            maxtime = timeout,
        })
        local elapsed = math.floor((now_seconds() - request_started) * 1000 + 0.5)
        if self:detectionOk(response) then
            return {
                online = true,
                latency_ms = elapsed,
                http_code = tonumber(response.code),
                probe_url = target,
                node = host,
            }
        end
        local reason
        if not response then
            reason = "无响应"
        elseif tonumber(response.code) ~= 200 then
            reason = "HTTP " .. text(response.code)
        else
            reason = "返回内容不是书山探测响应"
        end
        errors[#errors + 1] = self:hostLabel(host) .. "：" .. reason
    end

    return {
        online = false,
        probe_url = first_target or "",
        error = "没有可用的镜像节点\n" .. table.concat(errors, "\n"),
    }
end

function Shushan:runAction(source, action)
    action = text(action)
    if action:find("shushan_check", 1, true) then
        return self:checkNodes(source)
    end
    if action:find("shushan_login", 1, true) then
        return self:login(source, { force = true })
    end
    return false, "本机不支持该按钮：" .. action
end

return Shushan
