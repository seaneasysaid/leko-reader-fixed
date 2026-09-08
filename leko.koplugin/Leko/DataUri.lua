local DataUri = {}
local CryptoCompat = require("Leko/CryptoCompat")

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function percentDecode(value)
    value = tostring(value or "")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function base64Decode(value)
    return CryptoCompat.base64Decode(value)
end

local function hexEncode(value)
    return (tostring(value or ""):gsub(".", function(char)
        return string.format("%02x", char:byte())
    end))
end

local function hexDecode(value)
    value = tostring(value or ""):gsub("%s+", "")
    if #value % 2 ~= 0 or value:find("[^%x]") then return nil, "invalid hex payload" end
    return (value:gsub("(%x%x)", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function descriptorValue(descriptor, key)
    if type(descriptor) ~= "table" then return nil end
    if descriptor[key] ~= nil then return descriptor[key] end
    local camel = key:gsub("_([%a])", function(letter) return letter:upper() end)
    return descriptor[camel]
end

local function descriptorEncoding(descriptor)
    if type(descriptor) ~= "table" then return "" end
    for _, key in ipairs({ "result_encoding", "payload_encoding", "result_format", "payload_format", "encoding" }) do
        local value = descriptorValue(descriptor, key)
        if value ~= nil then return tostring(value):lower() end
    end
    return ""
end

-- Typed aggregate data: hand-offs expose their byte payload as hex to rules
-- that call java.hexDecodeToString(result), matching AnalyzeUrl on Android.
function DataUri:ruleInput(value, descriptor)
    value = tostring(value or "")
    local encoding = descriptorEncoding(descriptor)
    if encoding == "raw" or encoding == "plain" or encoding == "text" or encoding == "none" then
        return value
    end
    if encoding == "hex" or encoding == "hexadecimal" then
        local decoded, err = hexDecode(value)
        if not decoded then return nil, err end
        return value
    end
    if type(descriptor) == "table" and (descriptor.raw == true or descriptor.raw_result == true) then
        return value
    end
    return hexEncode(value)
end

function DataUri:is(value)
    return tostring(value or ""):lower():match("^data:") ~= nil
end

function DataUri:decode(value, options)
    options = options or {}
    value = trim(value)
    local metadata, payload = value:match("^[Dd][Aa][Tt][Aa]:([^,]*),(.*)$")
    if metadata == nil then return nil, "无效 data URI" end
    local is_base64 = metadata:lower():find(";base64", 1, true) ~= nil
    local media_type = metadata:match("^([^;]+)") or "text/plain"
    if media_type == "" or not media_type:find("/", 1, true) then media_type = "text/plain" end
    local body = is_base64 and base64Decode(payload) or percentDecode(payload)
    local max_bytes = tonumber(options.max_bytes) or (8 * 1024 * 1024)
    if #body > max_bytes then return nil, "data URI 内容过大" end
    return {
        body = body,
        content_type = media_type,
        metadata = metadata,
        base64 = is_base64,
    }
end

DataUri.percentDecode = percentDecode
DataUri.base64Decode = base64Decode

return DataUri
