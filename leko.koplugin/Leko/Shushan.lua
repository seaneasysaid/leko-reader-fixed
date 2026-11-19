-- Native (pure-Lua) driver for the 书山聚合 backend.
--
-- The upstream Legado source performs login, node selection, search, catalog
-- and chapter retrieval inside several megabytes of obfuscated JavaScript.
-- Running that on a Kindle/Kobo through the QuickJS bridge was the single
-- point of failure: no WebView for the login H5, evaluation timeouts on the
-- packed jsLib, and a 6 MB realm budget.  Everything that source does can be
-- expressed as a handful of HTTP calls, so this module does exactly that in
-- Lua.
--
-- Protocol: adapted 2026-11-19 to the v6.20261119.3 source.  The old unauth'd
-- endpoints (/login /search /catalog /content, static X-Novel-Token) were all
-- shut down (404 on every mirror).  v6 uses:
--   POST /api/login            -> data.token (short-lived, not a JWT)
--   GET  /api/search           -> data.list
--   POST /api/detail           -> data (book info)
--   POST /api/catalog          -> data (chapters, with identity fields inline)
--   POST /api/content          -> data.content
-- and signs every call with five x-novel-* headers.  Responses observed in
-- the wild are plain JSON; the JS keeps an AES-256-GCM fallback which we do
-- not need for the paths used here.
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
local socket = require("socket")

local Util = require("Leko/Util")
local Http = require("Leko/Http")

local Shushan = {}

Shushan.PREFIX = "leko://shushan"

-- Protocol constants from the v6.20261119.3 source (jsLib localVersion and
-- buildHeaders).  `version` travels in the /api/content body; `x-novel-version`
-- is a fixed header value and is NOT the source version.
Shushan.SOURCE_VERSION = "6.20261119.3"
Shushan.HEADER_VERSION = "10"
Shushan.USER_AGENT = "Mozilla/5.0 (Linux; Android 14; 23127PN0CC) "
    .. "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

-- The aggregate runs the same service behind several mirrors.  They are NOT
-- interchangeable per endpoint, so the node list is walked per request instead
-- of being pinned once at build time.  v5 was added in the v6 source; the two
-- IP mirrors are still listed there.
-- 顺序 = 优先顺序。2026-11-20 用真实请求重排（GET /api/site/public ×3）：
--   v4 0.29s · v5 0.43s · v1 0.65s · v2 1.62s · v3 2.37s ·
--   113.44.163.166 5.46s（IP 镜像慢一个数量级，只作兜底）。
Shushan.HOSTS = {
    "https://v4.vossc.com",
    "https://v5.vossc.com",
    "https://v1.vossc.com",
    "https://v2.vossc.com",
    "https://v3.vossc.com",
    "http://113.44.163.166:7001",
}

-- 已摘除的节点：`http://1.94.248.5:7001` 实测恒 502 / 10s 超时，2026-11-20
-- 从池子里拿掉。留这份名单只为一件事：它历史上被 _rememberHost 记成过首选并
-- 落进用户的 login_info，hostOrder 必须继续忽略这个旧值，否则每次请求又会先
-- 白等一个超时。
Shushan.RETIRED_HOSTS = {
    ["http://1.94.248.5:7001"] = true,
}

Shushan.REQUEST_TIMEOUT = 20
Shushan.MAX_BYTES = 4 * 1024 * 1024

-- SourceHealth asks for a health probe inside a forked worker that
-- AsyncSourceProbe kills after SOURCE_DEADLINE (7s).  The full six-mirror walk
-- used by the 检测节点 button cannot fit in that budget, so the probe gets an
-- explicit wall-clock allowance instead of relying on per-request timeouts to
-- add up favourably.  Keep PROBE_BUDGET comfortably below 7.
--
-- PROBE_TIMEOUT 是「单节点最多等多久」。实测 v3 正常时也要 2.4s、网络抖动时
-- 3.1–3.5s，设 3s 会把活着的节点判死（表现为「明明能看却报离线」），所以留 5s。
Shushan.PROBE_BUDGET = 6
Shushan.PROBE_HOSTS = 2
Shushan.PROBE_TIMEOUT = 5

-- loginUi field names, also used as the storage keys inside source.login_info.
Shushan.FIELD_EMAIL = "邮箱"
Shushan.FIELD_PASSWORD = "密码"
Shushan.FIELD_DEVICE = "设备ID"
-- Internal runtime keys (not declared in loginUi, so the UI never shows them).
-- v6 returns `token` from /api/login; we keep the old KEY_API slot so an
-- existing runtime file is reused and re-login simply overwrites it.
Shushan.KEY_API = "_api_key"
Shushan.KEY_HOST = "_host"

-- The rule engine derives a book's identity from its URL
-- (`book_id = "net-" .. hashId(source_id .. "\n" .. book_url)`), so this
-- payload must only ever carry fields that do not drift over time.  `wordCount`
-- and `latestChapterTitle` are deliberately absent: they change whenever the
-- book is updated, and including them would mint a new book id on every update
-- (duplicate shelf entries, lost reading progress).  They are not needed here
-- anyway - `ruleSearch` reads them straight off the search response.
-- v6 identity: the old `book_url` disappeared; a book is now addressed by
-- `sing` + `book_id` (+ source/tab).  These fields are stable across searches,
-- so packing them keeps the derived book id constant.  `word_count` and
-- `latest_chapter_title` stay out for the same reason as before.
local DETAIL_FIELDS = {
    "source", "sing", "bookid", "name", "tab", "author", "cover", "intro", "kind",
}
-- Chapter identity v6: the catalog supplies everything inline.  `curl`,
-- `itemid`, `title` are kept in the descriptor because ParaComments relies on
-- them (see Leko/ParaComments.lua chapterFields / platform).
local CHAPTER_FIELDS = { "source", "sing", "bookid", "itemid", "md5", "index", "tab", "name", "title", "curl" }

local AUTH_ERROR_NEEDLES = {
    "缺少登录凭证", "访问被拒绝", "未登录", "登录已过期", "凭证无效",
    "缺少认证", "非法请求", "请先登录", "登录失效", "token", "Token",
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

-- v6 request signing: x-novel-public = md5(base64_decode(token) .. device_id .. ts).
local function md5_hex(value)
    local ok, Digest = pcall(require, "Leko/Digest")
    if not ok or not Digest then return "" end
    local fine, result = pcall(function() return Digest:md5(text(value)) end)
    return fine and text(result) or ""
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

-- v5 packed the same idea with different field names and no book id:
--   detail  : source, url, name, tab, author, cover, intro, kind        (8)
--   chapter : source, cid, bookid, itemid, url, name, title, chapterid, curl (9)
-- Shelf entries and toc caches written back then are still on devices, so
-- decode them with the old layout when the part count matches instead of
-- shifting every value by one (`name` used to come out as "novel").
local DETAIL_FIELDS_V5 = {
    "source", "sing", "name", "tab", "author", "cover", "intro", "kind",
}
local CHAPTER_FIELDS_V5 = {
    "source", "cid", "bookid", "itemid", "sing", "name", "title", "chapterid", "curl",
}

local function unpack_fields(fields, raw, legacy_fields)
    local decoded = base64_decode(raw)
    if not decoded then return nil end
    local parts, position = {}, 1
    while true do
        local stop = decoded:find("\n", position, true)
        if stop then
            parts[#parts + 1] = decoded:sub(position, stop - 1)
            position = stop + 1
        else
            parts[#parts + 1] = decoded:sub(position)
            break
        end
    end
    local layout = fields
    if legacy_fields and #parts == #legacy_fields then layout = legacy_fields end
    local values = {}
    for index = 1, #layout do values[layout[index]] = parts[index] or "" end
    -- Legacy layouts omit keys the rest of the driver reads unconditionally
    -- (bookid / md5 / index / ...).  Normalise them to "" so no caller has to
    -- nil-check a descriptor field.
    for _, key in ipairs({ "source", "sing", "bookid", "itemid", "md5", "index",
        "tab", "name", "title", "author", "cover", "intro", "kind", "cid",
        "chapterid", "curl" }) do
        if values[key] == nil then values[key] = "" end
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
-- 节点质量的实测漂移很大：同一时刻 catalog v4 0.4s、v2 2.0s、v3 14.3s。
-- 静态顺序只在「所有节点都快」时成立，所以这里按进程内实测耗时重排：
-- 快的先试，最近一次超过 SLOW_HOST_SECONDS 的沉底（仍可兜底，只是不再挡路）。
-- 单次会话内的学习已经足够 —— 一台设备一次开机就有几十次请求。
Shushan.HOST_STATS = {}
Shushan.SLOW_HOST_SECONDS = 6
Shushan.UNKNOWN_HOST_SECONDS = 2.5

function Shushan:noteHostLatency(host, seconds)
    host = text(host):gsub("/+$", "")
    seconds = tonumber(seconds)
    if host == "" or not seconds or seconds <= 0 then return end
    local entry = self.HOST_STATS[host]
    if not entry then
        self.HOST_STATS[host] = { avg = seconds, last = seconds, count = 1 }
        return
    end
    -- 指数滑动平均：节点故障是按小时恢复的，最近几次比历史均值更有意义。
    entry.avg = entry.avg * 0.6 + seconds * 0.4
    entry.last, entry.count = seconds, (entry.count or 1) + 1
end

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
    -- 退役节点即便被记成 preferred 也不插队：插队等于每次请求先白等一个超时。
    -- 上次成功过的节点仍然第一优先（它刚刚证明了自己）。
    if preferred ~= "" and not self.RETIRED_HOSTS[preferred] then push(preferred) end

    local ranked = {}
    for index = 1, #self.HOSTS do
        local host = text(self.HOSTS[index]):gsub("/+$", "")
        local entry = self.HOST_STATS[host]
        ranked[#ranked + 1] = {
            host = host,
            index = index,
            avg = entry and entry.avg or self.UNKNOWN_HOST_SECONDS,
            slow = (entry and entry.last and entry.last >= self.SLOW_HOST_SECONDS) and 1 or 0,
        }
    end
    table.sort(ranked, function(a, b)
        if a.slow ~= b.slow then return a.slow < b.slow end
        -- 0.5s 以内视为同档，回落到静态顺序，避免被一次抖动长期锁死。
        if math.abs(a.avg - b.avg) > 0.5 then return a.avg < b.avg end
        return a.index < b.index
    end)
    for index = 1, #ranked do push(ranked[index].host) end
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

-- v6 headers are time-sensitive: x-novel-public = md5(decoded_token .. device
-- .. timestamp).  The token from /api/login is a base64 string; the JS decodes
-- it back to the "plain" value before hashing, so we do the same here.  When
-- no token is available yet (login itself) only the UA is sent.
-- /api/login answers `data.token = base64(plain)`.  Earlier builds saved the
-- decoded plain value (or an already-decoded token was typed in by hand); the
-- backend then answers 40102 "Token 错误" forever because the signature is
-- computed over atob(token).  A genuine token always decodes to printable
-- ASCII, so that round-trip is the cheapest reliable shape check.
function Shushan:tokenLooksSigned(value)
    local token = trim(value)
    if token == "" then return false end
    local decoded = base64_decode(token)
    if not decoded or decoded == "" then return false end
    for index = 1, #decoded do
        local byte = decoded:byte(index)
        if byte < 0x20 or byte > 0x7e then return false end
    end
    return true
end

function Shushan:baseHeaders(source, api_key)
    local headers = { ["User-Agent"] = self.USER_AGENT }
    local credentials = self:credentials(source)
    local token = trim(api_key) ~= "" and trim(api_key) or credentials.api_key
    if token == "" then return headers end

    local ts = tostring(math.floor(now_seconds()))
    local plain = base64_decode(token) or ""
    headers["x-novel-token"] = token
    headers["x-novel-deviceid"] = credentials.device_id
    headers["x-novel-timestamap"] = ts
    headers["x-novel-public"] = md5_hex(plain .. credentials.device_id .. ts)
    headers["x-novel-version"] = self.HEADER_VERSION
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
        -- 全书目录 973 KB / 搜索结果 270 KB，gzip 后分别是 78 KB / 一小部分。
        -- 设备 WiFi 实测：catalog 6.5s → 1.4s。只在文本接口开启，
        -- 封面图片仍走 identity（压缩纯浪费 CPU）。
        compress = true,
        -- v6 reports every business/auth failure as a real HTTP 4xx *with* a
        -- JSON body (40001 bad sing, 40102 bad token, ...).  Without this the
        -- transport swallows the body into a prose error and we can neither
        -- read `code` nor retry after re-login.
        allow_http_errors = true,
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
        local headers = self:baseHeaders(source, api_key)
        local url, method, body, extra = spec(host, headers)
        if type(extra) == "table" then
            for key, value in pairs(extra) do headers[key] = value end
        end

        local started = (socket and socket.gettime) and socket.gettime() or nil
        local response, err = self:fetch({
            url = url, method = method, headers = headers, body = body,
            timeout = options.timeout,
            maxtime = options.maxtime,
        })
        if started and socket and socket.gettime then
            local elapsed = socket.gettime() - started
            -- 失败也记：节点慢到超时正是最该沉底的情况。
            if response or elapsed >= self.SLOW_HOST_SECONDS then
                self:noteHostLatency(host, elapsed)
            end
        end

        -- v6 answers auth failures with a real HTTP 401 *and* a JSON body
        -- ({"code":40102,"message":"Token 错误"}).  Parsing only 200s used to
        -- hide the auth signal, so a stale token never triggered a re-login.
        local payload = response and decode_json(response.body) or nil
        local http_code = response and tonumber(response.code) or 0
        local message = payload and (payload.error or payload.message or payload.msg) or nil
        local body_code = payload and tonumber(payload.code) or nil
        local code_failed = body_code ~= nil and body_code ~= 0 and body_code ~= 200
        local is_auth = (code_failed and body_code >= 40100 and body_code < 40200)
            or contains_any(message, AUTH_ERROR_NEEDLES)

        if is_auth and not refreshed then
            refreshed = true
            api_key = self:apiKey(source, { force = true })
            if trim(api_key) ~= "" then
                payload, response = self:retryOnce(source, spec, host, api_key, options)
                http_code = response and tonumber(response.code) or 0
                message = payload and (payload.error or payload.message or payload.msg) or message
                body_code = payload and tonumber(payload.code) or body_code
                code_failed = body_code ~= nil and body_code ~= 0 and body_code ~= 200
            end
        end

        if payload and not code_failed and http_code >= 200 and http_code < 300
            and (not validate or validate(payload)) then
            self:_rememberHost(source, host)
            return payload, host
        end

        if payload then
            errors[#errors + 1] = self:hostLabel(host) .. "："
                .. (trim(message) ~= "" and trim(message)
                    or (code_failed and ("code " .. tostring(body_code)) or ("HTTP " .. text(http_code))))
        elseif response then
            local body_text = type(response.body) == "string" and trim(response.body) or ""
            if body_text ~= "" and #body_text <= 200 then
                errors[#errors + 1] = self:hostLabel(host) .. "：" .. body_text
            else
                errors[#errors + 1] = self:hostLabel(host) .. "：HTTP " .. text(http_code)
            end
        else
            errors[#errors + 1] = self:hostLabel(host) .. "：" .. text(err)
        end

        -- Auth/business codes are identical on every mirror; walking the rest
        -- cannot help and only burns time.  VIP/region reasons behave the same.
        if is_auth or code_failed then break end
        if (payload and message and contains_any(message, { "VIP", "会员", "付费", "版权", "授权" }))
            or (http_code >= 400 and http_code < 500) then break end
    end

    return nil, table.concat(errors, "\n")
end

function Shushan:retryOnce(source, spec, host, api_key, options)
    local headers = self:baseHeaders(source, api_key)
    local url, method, body, extra = spec(host, headers)
    if type(extra) == "table" then
        for key, value in pairs(extra) do headers[key] = value end
    end
    local response = self:fetch({
        url = url, method = method, headers = headers, body = body,
        timeout = options and options.timeout,
    })
    if not response then return nil, response end
    local payload = decode_json(response.body)
    if not payload then return nil, response end
    local body_code = tonumber(payload.code)
    if body_code and body_code ~= 0 and body_code ~= 200 then return nil, response end
    if tonumber(response.code) < 200 or tonumber(response.code) >= 300 then return nil, response end
    return payload, response
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

    -- v6: POST /api/login with a JSON body; the token lives at data.token
    -- (a short opaque string, NOT the JWT used by the comment web page).
    local body = rapidjson.encode({
        email = credentials.email,
        password = credentials.password,
    })
    for index = 1, limit do
        local host = hosts[index]
        local response, err = self:fetch({
            url = host .. "/api/login",
            method = "POST",
            headers = {
                ["User-Agent"] = self.USER_AGENT,
                ["Content-Type"] = "application/json",
            },
            body = body,
            timeout = 15,
        })
        if not response then
            errors[#errors + 1] = self:hostLabel(host) .. "：" .. text(err)
        else
            local payload = decode_json(response.body)
            local data = payload and type(payload.data) == "table" and payload.data or nil
            local token = data and trim(data.token) or ""
            local code = payload and tonumber(payload.code) or nil
            if payload and code == 0 and token ~= "" and self:tokenLooksSigned(token) then
                local group = type(data.group) == "table" and data.group or {}
                local member = type(data.membership) == "table" and data.membership or {}
                self._preferred = host
                self:setLoginInfo(source, {
                    [self.KEY_API] = token,
                    [self.KEY_HOST] = host,
                })
                local group_name = trim(group.name)
                local expires = trim(member.expires_at)
                return true, string.format("登录成功\n节点：%s\n令牌：%s%s%s",
                    self:hostLabel(host), self:mask(token),
                    group_name ~= "" and ("\n群组：" .. group_name) or "",
                    expires ~= "" and ("\n到期：" .. expires) or "")
            end
            local message = payload and (payload.message or payload.error or payload.msg)
            if payload and code == 0 and token ~= "" then
                message = "服务端返回的令牌格式异常（不是 base64）"
            end
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
    if credentials.api_key ~= "" and not options.force then
        -- Guard against a stale/hand-edited token that is not base64: the
        -- backend rejects it with 40102 on every node, so trade it for a fresh
        -- one instead of failing every request.
        if self:tokenLooksSigned(credentials.api_key) then return credentials.api_key end
        logger.warn("[LekoShushan] stored token is not base64, re-login")
    end
    if credentials.email == "" or credentials.password == "" then return credentials.api_key end
    local ok = self:login(source, { force = options.force })
    if not ok then return self:credentials(source).api_key end
    return self:credentials(source).api_key
end

function Shushan:search(source, keyword, page)
    keyword = trim(keyword)
    page = tonumber(page) or 1
    if keyword == "" then return nil, "请输入搜索关键词" end

    -- v6: GET /api/search?keyword=&page=&tab=novel -> data.list[*].
    -- The v5 `book_url` is gone; identity now comes from `sing` + `book_id`
    -- (see DETAIL_FIELDS).  Those ids are stable across searches.
    local query = "/api/search?keyword=" .. percent_encode(keyword)
        .. "&page=" .. tostring(page) .. "&tab=novel"
    local payload, host_or_err = self:requestJson(source,
        function(host) return host .. query end,
        function(value)
            return type(value.data) == "table" and type(value.data.list) == "table"
                and #value.data.list > 0
        end)

    if not payload then return nil, host_or_err end

    local results = {}
    for _, item in ipairs((payload.data and payload.data.list) or {}) do
        if type(item) == "table" then
            local title = trim(item.title)
            if title ~= "" then
                local detail = pack_fields(DETAIL_FIELDS, {
                    source = item.source, sing = item.sing, bookid = item.book_id,
                    name = title, tab = item.tab, author = item.author,
                    cover = item.cover, intro = item.desc, kind = item.tags,
                })
                local latest = trim(item.latest_chapter_title)
                -- 聚合源：结果行要能看出底层站点（番茄/QQ阅读/七猫……）。
                -- 只保留小说 tab；漫画/短剧/听书不进结果（Leko 只读书）。
                local tab = trim(item.tab)
                if tab == "" or tab == "novel" then
                    results[#results + 1] = {
                        name = title,
                        author = trim(item.author),
                        intro = trim(item.desc),
                        cover = trim(item.cover),
                        kind = trim(item.tags),
                        wordCount = trim(item.word_count),
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

-- v6 splits the old single /catalog into /api/detail (book info) and
-- /api/catalog (chapter list).  Both take the same identity body built from
-- the search descriptor.  Book info and toc run in different forked workers
-- and cannot share an in-process cache, so each step issues its own call.
local function detailBody(detail)
    return rapidjson.encode({
        source = trim(detail.source),
        sing = trim(detail.sing),
        book_id = trim(detail.bookid),
        title = trim(detail.name),
        tab = trim(detail.tab) ~= "" and trim(detail.tab) or "novel",
    })
end

-- `sing` is minted by /api/search: a v5-era shelf entry stores the old base64
-- detail URL there, and even a v6 token ages out ("sing 无效或已失效").  Both
-- conditions are terminal on every mirror, so the only cure is a fresh search
-- for the same title, reusing the row that matches the same origin site and
-- book id.  Cache per book so a long session pays the extra search once.
local FRESH_SING_TTL = 1800
local fresh_sing_cache = {}
-- Chapter heals re-derive identity from the catalog; keep the last catalog of
-- each book around briefly so healing several chapters is one extra call, not
-- one per chapter.
local fresh_catalog_cache = {}
local FRESH_CATALOG_TTL = 300

local function needsFreshSing(message)
    message = text(message)
    return message:find("sing 无效", 1, true) ~= nil
        or message:find("sing 不能为空", 1, true) ~= nil
end

local function singCacheKey(detail)
    local bookid = trim(detail.bookid)
    if bookid ~= "" then return bookid end
    return trim(detail.source) .. "|" .. trim(detail.name)
end

function Shushan:resolveDetail(source, detail)
    local key = singCacheKey(detail)
    local cached = key ~= "" and fresh_sing_cache[key] or nil
    if cached and cached.at and (now_seconds() - cached.at) < FRESH_SING_TTL then
        return cached.values
    end

    local name = trim(detail.name)
    if name == "" then return nil end
    local result = self:search(source, name, 1)
    local rows = type(result) == "table" and result.results or {}
    local wanted_source = trim(detail.source)
    local wanted_bookid = trim(detail.bookid)
    local exact, same_title

    for index = 1, #rows do
        local row = rows[index]
        local ok, values = pcall(function() return select(2, self:parseUrl(row.bookUrl)) end)
        if ok and type(values) == "table" and trim(values.sing) ~= "" then
            local same_site = wanted_source == "" or trim(values.source) == wanted_source
            if same_site and wanted_bookid ~= "" and trim(values.bookid) == wanted_bookid then
                exact = values
            elseif same_site and trim(values.name) == name and not same_title then
                same_title = values
            end
        end
    end

    local values = exact or same_title
    if not values then
        logger.warn(string.format("[LekoShushan] sing refresh miss for %s (rows=%d)",
            name, #rows))
        return nil
    end
    if key ~= "" then fresh_sing_cache[key] = { values = values, at = now_seconds() } end
    logger.info(string.format("[LekoShushan] refreshed sing for %s (%s)",
        trim(values.name), trim(values.bookid)))
    return values
end

function Shushan:requestDetail(source, detail)
    if trim(detail.sing) == "" and trim(detail.bookid) == "" then
        return nil, "书源没有返回书籍标识（sing/book_id）"
    end
    local function attempt(values)
        local body = detailBody(values)
        return self:requestJson(source,
            function(host)
                return host .. "/api/detail", "POST", body,
                    { ["Content-Type"] = "application/json" }
            end,
            function(value) return type(value.data) == "table" end,
            { timeout = 30, max_hosts = 4 })
    end

    local payload, err = attempt(detail)
    if payload then return payload, nil, detail end
    if not needsFreshSing(err) then return nil, err end
    local fresh = self:resolveDetail(source, detail)
    if not fresh then return nil, err end
    payload, err = attempt(fresh)
    if payload then return payload, nil, fresh end
    return nil, err
end

function Shushan:requestCatalog(source, detail)
    if trim(detail.sing) == "" and trim(detail.bookid) == "" then
        return nil, "书源没有返回书籍标识（sing/book_id）"
    end
    local function attempt(values)
        local body = detailBody(values)
        return self:requestJson(source,
            function(host)
                return host .. "/api/catalog", "POST", body,
                    { ["Content-Type"] = "application/json" }
            end,
            function(value)
                return type(value.data) == "table" and #value.data > 0
            end,
            { timeout = 30, max_hosts = 4 })
    end

    local payload, err = attempt(detail)
    if payload then return payload, nil, detail end
    if not needsFreshSing(err) then return nil, err end
    local fresh = self:resolveDetail(source, detail)
    if not fresh then return nil, err end
    payload, err = attempt(fresh)
    if payload then return payload, nil, fresh end
    return nil, err
end

function Shushan:book(source, detail)
    local payload, err, resolved = self:requestDetail(source, detail)
    if not payload then return nil, err end
    detail = resolved or detail
    -- The detail response carries the authoritative title/cover/desc; fall
    -- back to the search descriptor for any field the server left blank.
    local info = type(payload.data) == "table" and payload.data or {}
    return {
        name = trim(info.title) ~= "" and trim(info.title) or trim(detail.name),
        author = trim(info.author) ~= "" and trim(info.author) or trim(detail.author),
        intro = trim(info.desc) ~= "" and trim(info.desc) or trim(detail.intro),
        cover = trim(info.cover) ~= "" and trim(info.cover) or trim(detail.cover),
        kind = trim(info.tags) ~= "" and trim(info.tags) or trim(detail.kind),
        tocUrl = self.PREFIX .. "/toc?d=" .. base64_encode(pack_fields(DETAIL_FIELDS, detail)),
    }
end

function Shushan:toc(source, detail)
    local payload, err, resolved = self:requestCatalog(source, detail)
    if not payload then return nil, err end
    detail = resolved or detail

    local source_name = trim(detail.source)
    local book_name = trim(detail.name)
    local bookid = trim(detail.bookid)
    -- v6 catalog rows carry the full content identity inline:
    --   sing / book_id / item_id / content_md5 / chapter_index / source / tab.
    -- No more client-side URL parsing.  Volume rows are skipped.
    local chapters = {}
    for _, item in ipairs(payload.data or {}) do
        if type(item) == "table" and item.is_volume ~= true then
            local fields = {
                source = trim(item.source) ~= "" and trim(item.source) or source_name,
                sing = trim(item.sing) ~= "" and trim(item.sing) or trim(detail.sing),
                bookid = trim(item.book_id) ~= "" and trim(item.book_id) or bookid,
                itemid = trim(item.item_id),
                md5 = trim(item.content_md5),
                index = int_text(item.chapter_index),
                tab = trim(item.tab) ~= "" and trim(item.tab) or trim(detail.tab),
                name = book_name,
                title = trim(item.title),
                -- curl is retained for ParaComments parity; v6 has no per-
                -- chapter URL, so build one carrying the same identity.
                curl = "item_id=" .. trim(item.item_id)
                    .. "&book_id=" .. (trim(item.book_id) ~= "" and trim(item.book_id) or bookid)
                    .. "&content_md5=" .. trim(item.content_md5),
            }
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

-- Rebuilds a chapter identity from a fresh catalog.  Used when /api/content
-- rejects the descriptor we hold (v5 toc cache, or an aged-out sing): the
-- catalog row carries the current sing / item_id / content_md5 trio.
function Shushan:rebuildChapter(source, chapter)
    local book_name = trim(chapter.name)
    if book_name == "" then return nil end

    local detail = self:resolveDetail(source, {
        name = book_name,
        source = trim(chapter.source),
        bookid = trim(chapter.bookid),
    })
    if not detail then
        logger.warn("[LekoShushan] chapter heal: book not found · " .. book_name)
        return nil
    end

    local cache_key = trim(chapter.bookid) .. "|" .. trim(chapter.source) .. "|" .. book_name
    local cached = fresh_catalog_cache[cache_key]
    local rows, base
    if cached and (now_seconds() - cached.at) < FRESH_CATALOG_TTL then
        rows, base = cached.rows, cached.base
    else
        local payload, err, resolved = self:requestCatalog(source, detail)
        rows = payload and type(payload.data) == "table" and payload.data or nil
        if not rows then
            logger.warn("[LekoShushan] chapter heal: catalog failed · " .. book_name
                .. " · " .. text(err))
            return nil
        end
        base = resolved or detail
        fresh_catalog_cache[cache_key] = { rows = rows, base = base, at = now_seconds() }
    end
    local wanted_item = trim(chapter.itemid)
    local wanted_title = trim(chapter.title)
    local wanted_index = tonumber(chapter.index) or tonumber(chapter.chapterid)
    local by_item, by_title, by_index
    for index = 1, #rows do
        local row = rows[index]
        if type(row) == "table" and row.is_volume ~= true then
            if wanted_item ~= "" and trim(row.item_id) == wanted_item then
                by_item = row
            elseif wanted_title ~= "" and trim(row.title) == wanted_title then
                by_title = by_title or row
            elseif wanted_index and tonumber(row.chapter_index) == wanted_index then
                by_index = by_index or row
            end
        end
    end

    local row = by_item or by_title or by_index
    if not row then
        logger.warn("[LekoShushan] chapter heal: no match for " .. text(wanted_title))
        return nil
    end

    return {
        source = trim(row.source) ~= "" and trim(row.source) or trim(base.source),
        sing = trim(row.sing) ~= "" and trim(row.sing) or trim(base.sing),
        bookid = trim(row.book_id) ~= "" and trim(row.book_id) or trim(base.bookid),
        itemid = trim(row.item_id),
        md5 = trim(row.content_md5),
        index = int_text(row.chapter_index),
        tab = trim(row.tab) ~= "" and trim(row.tab) or trim(base.tab),
        name = book_name,
        title = trim(row.title),
    }
end

-- The chapter body is plain UTF-8 text served by the aggregate; v6 needs the
-- catalog-supplied identity (sing/book_id/item_id/content_md5/chapter_index),
-- a registered device id in the signed headers, and `version` = source version
-- in the body.  The normal reader path deliberately does NOT send review=on:
-- that embeds comment bubbles as inline SVG <img> tags.  The 段评 counts path
-- uses chapterWithReview below to ask for those bubbles and parse the counts.
function Shushan:fetchContent(source, chapter, with_review, options)
    options = options or {}
    local credentials = self:credentials(source)
    if credentials.device_id == "" then
        return nil, "缺少设备ID\n请到「书源 → 书山聚合（原生）→ 配置书源」填写一本机已登记的设备ID"
    end

    local function attempt(values)
        local body = {
            sing = trim(values.sing),
            book_id = trim(values.bookid),
            item_id = trim(values.itemid),
            content_md5 = trim(values.md5),
            chapter_index = tonumber(values.index) or 0,
            source = trim(values.source),
            tab = trim(values.tab) ~= "" and trim(values.tab) or "novel",
            version = self.SOURCE_VERSION,
            devicetype = "android",
        }
        if with_review then
            -- Only these platforms render 段评 bubbles server-side (v6 source
            -- ruleContent: paraSources).  Sending review=on for others is harmless
            -- but pointless, so only set it when the source is one of them.
            body.review = "on"
            body.style = "TEXT"
        end

        local encoded = rapidjson.encode(body)
        return self:requestJson(source,
            function(host)
                return host .. "/api/content", "POST", encoded,
                    { ["Content-Type"] = "application/json" }
            end,
            function(value)
                local data = value.data
                local content = type(data) == "table" and text(data.content) or ""
                if content == "" then return false end
                -- A mirror can answer 200 with a human-readable outage notice.
                if contains_any(content, NODE_ERROR_NEEDLES) then return false end
                return true
            end,
            { timeout = tonumber(options.timeout) or 60,
              -- 冷章节（第一次有人读）服务端要去上游抓，实测 41s 才回；
              -- 之后同一章 3–4s。30s 的旧上限会把这类章节直接判死，
              -- 然后白轮换到下一个节点重新等一遍。
              maxtime = tonumber(options.maxtime) or 120,
              max_hosts = tonumber(options.max_hosts) or 2 })
    end

    local payload, host_or_err = attempt(chapter)

    -- A chapter descriptor cached from a v5 toc (or one whose sing aged out)
    -- cannot be replayed: /api/content answers 40001.  Re-derive the identity
    -- from a fresh catalog and retry once, matching on item id, chapter title
    -- and finally chapter index.
    if not payload and needsFreshSing(host_or_err) then
        local fresh = self:rebuildChapter(source, chapter)
        if fresh then payload, host_or_err = attempt(fresh) end
    end

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

function Shushan:chapter(source, chapter)
    return self:fetchContent(source, chapter, false)
end

-- Raw正文 with 段评 SVG bubbles embedded (review=on).  Used only by
-- Leko/ParaComments to recover per-paragraph comment counts; never rendered
-- directly to the reader.
function Shushan:chapterWithReview(source, chapter, options)
    return self:fetchContent(source, chapter, true, options)
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
    if action == "chapter" then
        return action, unpack_fields(CHAPTER_FIELDS, raw, CHAPTER_FIELDS_V5) or {}
    end
    return action, unpack_fields(DETAIL_FIELDS, raw, DETAIL_FIELDS_V5) or {}
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
-- is alive" means, so the predicate lives in one place.  In v6 the old
-- /detection path is 404 everywhere; /api/site/public is the public, auth-free
-- liveness endpoint and its JSON carries "书山聚合" as site_name.  A 200 alone
-- is not enough (an unrelated server answers 200 for any path), so check body.
Shushan.DETECTION_PATH = "/api/site/public"

function Shushan:detectionOk(response)
    if not response or tonumber(response.code) ~= 200 then return false end
    local body = text(response.body)
    if body:find("书山", 1, true) then return true end
    -- Also accept a valid v6 JSON envelope (code 0) in case the site name is
    -- ever changed by the upstream.
    local payload = decode_json(body)
    return type(payload) == "table" and tonumber(payload.code) == 0
end

function Shushan:checkNodes(source)
    local lines, best, best_ms = {}, nil, nil
    for index = 1, #self.HOSTS do
        local host = self.HOSTS[index]
        local started = now_seconds()
        local response = self:fetch({
            url = host .. self.DETECTION_PATH,
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

-- Reports whether any mirror answers /api/site/public right now.
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
        local target = host .. self.DETECTION_PATH
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
