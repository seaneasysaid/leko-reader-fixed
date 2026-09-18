-- Conservative capability gate for aggregate-source loginUi actions.
--
-- The expensive part is deliberately separated from rendering: prepare()
-- indexes jsLib/loginUrl once, evaluates every distinct action once, and
-- stores only the compact verdicts.  The configuration page calls label(),
-- which never scans or evaluates source-owned JavaScript.
local Util = require("Leko/Util")

local Capability = {
    cache_version = 2,
    runtime_capability_version = "kindle-native-host-2",
}

local NATIVE_JAVA = {
    ajax = true, ajaxAll = true, ajaxTestAll = true, connect = true,
    get = true, post = true, head = true, put = true,
    getCookie = true, setCookie = true, removeCookie = true,
    base64Encode = true, base64Decode = true, hexDecodeToString = true,
    base64DecodeToByteArray = true, bytesToStr = true,
    hexEncodeToString = true, md5Encode = true, md5Encode16 = true,
    digestHex = true, HMacHex = true, HMacBase64 = true,
    randomUUID = true, createSymmetricCrypto = true,
    aesBase64DecodeToString = true, desEncodeToBase64String = true,
    urlEncode = true, urlDecode = true, encodeURI = true,
    getString = true, getStringList = true, getElements = true,
    setContent = true, getStrResponse = true, getUserAgent = true,
    getWebViewUA = true, androidId = true, deviceID = true,
    s2t = true, t2s = true, toNumChapter = true,
    timeFormat = true, timeFormatUTC = true,
    htmlFormat = true, log = true, toast = true, longToast = true,
    refreshTocUrl = true, refreshContent = true, refreshBookUrl = true,
    refreshBookInfo = true, refreshExplore = true, searchBook = true,
    upLoginData = true, initUrl = true,
}

local SAFE_GLOBAL_CALLS = {
    String = true, Number = true, Boolean = true, Object = true, Array = true,
    Math = true, Date = true, RegExp = true, Error = true, TypeError = true,
    Map = true, Set = true, URL = true, URLSearchParams = true,
    JSON = true, Promise = true, parseInt = true, parseFloat = true,
    isNaN = true, isFinite = true, encodeURIComponent = true,
    decodeURIComponent = true, encodeURI = true, decodeURI = true,
    escape = true, unescape = true, atob = true, btoa = true,
}

local function text(value) return tostring(value == nil and "" or value) end
local function lower(value) return text(value):lower() end

local function scriptText(value, output)
    output = output or {}
    if type(value) == "table" then
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do scriptText(value[key], output) end
    elseif value ~= nil then
        output[#output + 1] = tostring(value)
    end
    return table.concat(output, "\n")
end

-- Replace strings/comments with spaces while preserving byte offsets.  This
-- gives the old inspect() semantics without repeatedly rescanning a large
-- library for every button and every reachable helper.
local function codeSurface(value)
    value = text(value)
    local output, index, quote, escaped = {}, 1, nil, false
    local line_comment, block_comment = false, false
    while index <= #value do
        local char, next_char = value:sub(index, index), value:sub(index + 1, index + 1)
        if line_comment then
            output[#output + 1] = char == "\n" and "\n" or " "
            if char == "\n" then line_comment = false end
        elseif block_comment then
            output[#output + 1] = char == "\n" and "\n" or " "
            if char == "*" and next_char == "/" then
                output[#output + 1] = " "; index = index + 1; block_comment = false
            end
        elseif quote then
            output[#output + 1] = char == "\n" and "\n" or " "
            if escaped then escaped = false
            elseif char == "\\" then escaped = true
            elseif char == quote then quote = nil end
        elseif char == "/" and next_char == "/" then
            output[#output + 1] = "  "; index = index + 1; line_comment = true
        elseif char == "/" and next_char == "*" then
            output[#output + 1] = "  "; index = index + 1; block_comment = true
        elseif char == "'" or char == '"' or char == "`" then
            output[#output + 1] = " "; quote, escaped = char, false
        else
            output[#output + 1] = char
        end
        index = index + 1
    end
    return table.concat(output)
end

local function matchingBrace(surface, open)
    local depth = 1
    for index = open + 1, #surface do
        local char = surface:sub(index, index)
        if char == "{" then depth = depth + 1
        elseif char == "}" then
            depth = depth - 1
            if depth == 0 then return index end
        end
    end
    return nil
end

local function buildFunctionIndex(script)
    script = scriptText(script)
    local surface, found = codeSurface(script), {}
    local candidates = {}
    local function collect(pattern)
        local position = 1
        while position <= #surface do
            local start_at, end_at, name = surface:find(pattern, position)
            if not start_at then break end
            candidates[#candidates + 1] = { start_at = start_at, end_at = end_at, name = name }
            position = end_at + 1
        end
    end
    collect("function%s+([A-Za-z_$][%w_$]*)%s*%b()%s*{")
    collect("([A-Za-z_$][%w_$]*)%s*=%s*function%s*%b()%s*{")
    table.sort(candidates, function(a, b) return a.start_at < b.start_at end)
    for _, candidate in ipairs(candidates) do
        if found[candidate.name] == nil then
            local open = surface:find("{", candidate.start_at, true)
            local close = open and matchingBrace(surface, open)
            if close then found[candidate.name] = script:sub(open + 1, close - 1) end
        end
    end
    return found
end

local function hasForbidden(value)
    local surface = lower(value)
    for _, pattern in ipairs({
        "startbrowser", "webview", "showbrowser", "openbrowser", "loadurl",
        "getverificationcode", "document%.", "window%.", "fetch%s*%(",
        "xmlhttprequest", "navigator%.", "queryselector", "addeventlistener",
        "requestsubmit", "%.click%s*%(", "packages%.", "java%.io",
        "java%.net", "java%.lang%.runtime", "prompt%s*%(",
    }) do
        if surface:find(pattern) then return true end
    end
    return false
end

local function javaMethods(value)
    local result = {}
    for method in text(value):gmatch("java%.([A-Za-z_$][%w_$]*)%s*%(") do
        result[#result + 1] = method
    end
    return result
end

local function calledFunctions(value)
    local result, seen, position = {}, {}, 1
    value = text(value)
    while position <= #value do
        local start_at, end_at, name = value:find("([A-Za-z_$][%w_$]*)%s*%(", position)
        if not start_at then break end
        local previous = value:sub(start_at - 1, start_at - 1)
        if previous ~= "." and not seen[name] and not SAFE_GLOBAL_CALLS[name]
                and name ~= "if" and name ~= "for" and name ~= "while"
                and name ~= "switch" and name ~= "catch" and name ~= "function"
                and name ~= "return" and name ~= "typeof" then
            seen[name] = true
            result[#result + 1] = name
        end
        position = end_at + 1
    end
    return result
end

local function inspectIndexed(indexes, action)
    action = text(action)
    if action:match("^%s*https?://") then return false, "需要浏览器页面" end
    if action:gsub("%s+", "") == "" then return false, "没有 action" end
    local queue, seen, index = { action }, {}, 1
    while index <= #queue and index <= 48 do
        local surface = codeSurface(queue[index] or "")
        index = index + 1
        if hasForbidden(surface) then return false, "需要浏览器或页面脚本" end
        for _, method in ipairs(javaMethods(surface)) do
            if not NATIVE_JAVA[method] then
                return false, "调用了 Kindle 不支持的 java." .. tostring(method)
            end
        end
        for _, name in ipairs(calledFunctions(surface)) do
            if not seen[name] then
                seen[name] = true
                local body
                for _, function_index in ipairs(indexes) do
                    body = function_index[name]
                    if body then break end
                end
                if not body then return false, "调用了未定义的脚本函数" end
                queue[#queue + 1] = body
            end
        end
    end
    return true, "native"
end

local function rawDefinition(source, raw_name, normalized_name)
    if source and source[normalized_name] ~= nil then return source[normalized_name] end
    local raw = type(source and source.raw) == "table" and source.raw or source or {}
    return raw[raw_name] or raw[normalized_name] or ""
end

function Capability.definitionSignature(source)
    local js_lib = scriptText(rawDefinition(source, "jsLib", "js_lib"))
    local login_url = scriptText(rawDefinition(source, "loginUrl", "login_url"))
    local login_ui = scriptText(rawDefinition(source, "loginUi", "login_ui"))
    return table.concat({
        tostring(Capability.cache_version), Capability.runtime_capability_version,
        Util.hashId(js_lib), Util.hashId(login_url), Util.hashId(login_ui),
    }, ":")
end

function Capability.bindDefinition(source)
    if type(source) ~= "table" then return nil end
    source.action_capability_definition_signature = Capability.definitionSignature(source)
    return source.action_capability_definition_signature
end

local function signature(source)
    return source and source.action_capability_definition_signature
        or Capability.bindDefinition(source)
end

function Capability.isPrepared(source, actions)
    local cache = type(source) == "table" and source.action_capability_cache or nil
    if type(cache) ~= "table" or cache.signature ~= signature(source)
            or type(cache.actions) ~= "table" then return false end
    for _, row in ipairs(actions or {}) do
        local action = type(row) == "table" and row.action or row
        if cache.actions[text(action)] == nil then return false end
    end
    return true
end

function Capability.prepare(source, actions, options)
    options = type(options) == "table" and options or {}
    if type(source) ~= "table" then return nil, "书源对象无效" end
    if Capability.isPrepared(source, actions) then return source.action_capability_cache end
    local js_lib = rawDefinition(source, "jsLib", "js_lib")
    local login_url = rawDefinition(source, "loginUrl", "login_url")
    local indexes = { buildFunctionIndex(login_url), buildFunctionIndex(js_lib) }
    local old_cache = type(source.action_capability_cache) == "table"
        and source.action_capability_cache.signature == signature(source)
        and source.action_capability_cache or nil
    local cache = {
        signature = signature(source), actions = {},
        generated_at = old_cache and old_cache.generated_at or os.time(),
    }
    for action, verdict in pairs(old_cache and old_cache.actions or {}) do
        if type(verdict) == "table" then
            cache.actions[action] = { supported = verdict.supported == true, reason = verdict.reason }
        end
    end
    local unique, total = {}, 0
    for _, row in ipairs(actions or {}) do
        local action = text(type(row) == "table" and row.action or row)
        if not unique[action] and cache.actions[action] == nil then
            unique[action] = true; total = total + 1
        end
    end
    local completed = 0
    for _, row in ipairs(actions or {}) do
        local action = text(type(row) == "table" and row.action or row)
        if cache.actions[action] == nil then
            -- Preserve old inspect() lookup precedence: definitions inside the
            -- action itself, then loginUrl, then jsLib.
            local action_index = buildFunctionIndex(action)
            local supported, reason = inspectIndexed({ action_index, indexes[1], indexes[2] }, action)
            cache.actions[action] = { supported = supported == true, reason = reason }
            completed = completed + 1
            if type(options.on_progress) == "function" then
                pcall(options.on_progress, completed, total, action)
            end
        end
    end
    source.action_capability_cache = cache
    return cache
end

function Capability.inspect(source, action)
    local cache, err = Capability.prepare(source, { action })
    if not cache then return false, err or "能力判定失败" end
    local verdict = cache.actions[text(action)]
    return verdict and verdict.supported == true or false,
        verdict and verdict.reason or "未生成能力判定"
end

function Capability.label(source, action)
    local cache = type(source) == "table" and source.action_capability_cache or nil
    local verdict = cache and cache.signature == signature(source)
        and type(cache.actions) == "table" and cache.actions[text(action)] or nil
    if verdict and verdict.supported == true then return "Kindle 可执行", true, verdict.reason end
    return "不支持（当前 Kindle 运行时无法执行）", false,
        verdict and verdict.reason or "尚未完成能力判定"
end

return Capability
