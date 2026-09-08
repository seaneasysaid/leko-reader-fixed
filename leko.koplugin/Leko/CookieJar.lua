-- Small persistent cookie jar stored inside each normalized source record.
local CookieJar = {}

local function lower(value) return tostring(value or ""):lower() end
local function hostOf(url)
    return lower(tostring(url or ""):match("^https?://([^/%?:]+)") or "")
end
local function pathOf(url)
    local path = tostring(url or ""):match("^https?://[^/]+(/[^%?#]*)") or "/"
    return path ~= "" and path or "/"
end
local function defaultPath(url)
    local path = pathOf(url)
    if path == "/" then return "/" end
    local parent = path:match("^(.*)/")
    return parent and parent ~= "" and parent or "/"
end
local function domainMatches(host, domain)
    domain = lower(domain):gsub("^%.", "")
    return host == domain or host:sub(-#domain - 1) == "." .. domain
end

-- A script may set a ready-to-send Cookie header rather than a Set-Cookie
-- response. Keep it URL-scoped; it has no synthetic Domain/Path attributes.
local function rawCookieKey(url)
    return "__leko_raw_cookie:" .. tostring(url or "")
end

local MONTHS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

local function utcTime(fields)
    local local_time = os.time(fields)
    if not local_time then return nil end
    local utc_fields = os.date("!*t", local_time)
    local utc_as_local = os.time(utc_fields)
    return local_time + (local_time - utc_as_local)
end

local function parseExpires(value)
    value = tostring(value or "")
    local day, month, year, hour, minute, second = value:match(
        "^%s*[^,]*,?%s*(%d%d?)%s+([A-Za-z]+)%s+(%d%d%d?%d?)%s+(%d%d?):(%d%d):(%d%d)")
    if not day then
        day, month, year, hour, minute, second = value:match(
            "^%s*(%d%d?)%-([A-Za-z]+)%-(%d%d)%s+(%d%d?):(%d%d):(%d%d)")
    end
    if not day then return nil end
    month = MONTHS[lower(month):sub(1, 3)]
    year, day = tonumber(year), tonumber(day)
    if not month or not year or not day then return nil end
    if year < 100 then year = year >= 70 and year + 1900 or year + 2000 end
    if year < (tonumber(os.date("!*t").year) or 1971) then return 0 end
    local ok, timestamp = pcall(utcTime, {
        year = year, month = month, day = day,
        hour = tonumber(hour) or 0, min = tonumber(minute) or 0,
        sec = tonumber(second) or 0, isdst = false,
    })
    return ok and timestamp or nil
end

local function parseSetCookie(value, request_url)
    local first, rest = tostring(value or ""):match("^%s*([^;]+)%s*;?(.*)$")
    if not first then return nil end
    local name, cookie_value = first:match("^%s*([^=]+)%s*=%s*(.*)$")
    if not name then return nil end
    local cookie = {
        name = name,
        value = cookie_value or "",
        domain = hostOf(request_url),
        path = defaultPath(request_url),
        secure = false,
        host_only = true,
    }
    local max_age_seen = false
    for attribute in tostring(rest or ""):gmatch("[^;]+") do
        local key, val = attribute:match("^%s*([^=]+)%s*=?%s*(.-)%s*$")
        key = lower(key)
        if key == "domain" and val ~= "" then
            cookie.domain = lower(val):gsub("^%.", "")
            cookie.host_only = false
        elseif key == "path" and val ~= "" then cookie.path = val
        elseif key == "secure" then cookie.secure = true
        elseif key == "max-age" then
            local seconds = tonumber(val)
            if seconds then
                cookie.expires = os.time() + seconds
                max_age_seen = true
            end
        elseif key == "expires" and not max_age_seen then
            cookie.expires = parseExpires(val)
        end
    end
    return cookie
end

function CookieJar:add(source, request_url, set_cookie)
    if not source or source.enabled_cookie_jar == false or not set_cookie then return false end
    source.cookies = source.cookies or {}
    local values = type(set_cookie) == "table" and set_cookie or { set_cookie }
    local changed = false
    for _, raw in ipairs(values) do
        local cookie = parseSetCookie(raw, request_url)
        if cookie then
            local key = cookie.domain .. "\t" .. cookie.path .. "\t" .. cookie.name
            if cookie.value == "" or (cookie.expires and cookie.expires <= os.time()) then
                source.cookies[key] = nil
            else
                source.cookies[key] = cookie
            end
            changed = true
        end
    end
    return changed
end

function CookieJar:addFromHeaders(source, request_url, headers)
    if type(headers) ~= "table" then return false end
    return self:add(source, request_url, headers["set-cookie"] or headers["Set-Cookie"])
end

function CookieJar:setHeader(source, request_url, value)
    if not source or source.enabled_cookie_jar == false then return false end
    source.cookies = source.cookies or {}
    local key = rawCookieKey(request_url)
    value = tostring(value or "")
    if value == "" then source.cookies[key] = nil else source.cookies[key] = value end
    return true
end

function CookieJar:remove(source, request_url)
    if not source or type(source.cookies) ~= "table" then return false end
    local wanted = tostring(request_url or "")
    local wanted_host = hostOf(wanted)
    local removed = false
    for key, cookie in pairs(source.cookies) do
        local match = key == rawCookieKey(wanted) or key == wanted
        if not match and wanted_host ~= "" then
            if type(cookie) == "string" then
                local cookie_url = tostring(key or ""):match("^https?://")
                    and tostring(key) or tostring(key or ""):match("^__leko_raw_cookie:(https?://.*)$")
                match = cookie_url ~= nil and hostOf(cookie_url) == wanted_host
            elseif type(cookie) == "table" and cookie.domain then
                local domain = lower(cookie.domain):gsub("^%.", "")
                match = cookie.host_only and wanted_host == domain
                    or not cookie.host_only and domainMatches(wanted_host, domain)
            end
        end
        if match then source.cookies[key] = nil; removed = true end
    end
    return removed
end

function CookieJar:header(source, request_url)
    if not source or source.enabled_cookie_jar == false then return "" end
    local host, path = hostOf(request_url), pathOf(request_url)
    local secure = tostring(request_url or ""):match("^https://") ~= nil
    local values = {}
    for key, cookie in pairs(source.cookies or {}) do
        if type(cookie) == "string" then
            local key_text = tostring(key or "")
            local cookie_url = key_text:match("^https?://") and key_text
                or key_text:match("^__leko_raw_cookie:(https?://.*)$") or ""
            if cookie_url ~= "" and hostOf(cookie_url) == host then values[#values + 1] = cookie end
        elseif type(cookie) == "table" and cookie.expires and cookie.expires <= os.time() then
            source.cookies[key] = nil
        elseif type(cookie) == "table" and (not cookie.secure or secure)
            and (cookie.host_only and host == cookie.domain or (not cookie.host_only and domainMatches(host, cookie.domain)))
            and path:sub(1, #cookie.path) == cookie.path then
            table.insert(values, cookie.name .. "=" .. cookie.value)
        end
    end
    table.sort(values)
    return table.concat(values, "; ")
end

return CookieJar
