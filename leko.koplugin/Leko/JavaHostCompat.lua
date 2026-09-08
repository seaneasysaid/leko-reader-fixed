-- Narrow, explicit Legado Java compatibility layer.
--
-- This module is deliberately independent of QuickJS.  QuickJS owns the
-- JavaScript facade and forwards opaque object calls here; this module owns
-- the small Java/Legado semantics that can be reproduced safely on KOReader.
-- It is not a JVM and the registry is intentionally closed.
local CompressionCompat = require("Leko/CompressionCompat")

local JavaHostCompat = {}

local MAX_BYTES = 8 * 1024 * 1024
local MAX_GZIP_INPUT = 8 * 1024 * 1024
local MAX_GZIP_OUTPUT = 8 * 1024 * 1024
local MAX_GZIP_RATIO = 100

local PACKAGE_CLASSES = {
    ["java.lang"] = { String = true, System = true },
    ["java.math"] = { BigInteger = true },
    ["java.io"] = {
        ByteArrayInputStream = true,
        ByteArrayOutputStream = true,
    },
    ["java.util"] = { Base64 = true, Arrays = true, UUID = true },
    ["java.util.zip"] = { GZIPInputStream = true },
    ["java.security"] = { KeyFactory = true, Signature = true },
    ["java.security.interfaces"] = { RSAPrivateKey = true, RSAPublicKey = true },
    ["java.security.spec"] = { PKCS8EncodedKeySpec = true, X509EncodedKeySpec = true, RSAPublicKeySpec = true },
    ["javax.crypto"] = { Cipher = true, Mac = true },
    ["javax.crypto.spec"] = { SecretKeySpec = true, IvParameterSpec = true },
    ["org.jsoup"] = { Jsoup = true, Connection = true },
    ["okhttp3"] = { OkHttpClient = true, Request = true, RequestBody = true, MediaType = true, Headers = true },
    ["cn.hutool.core.util"] = { StrUtil = true, ZipUtil = true },
    ["cn.hutool.core.codec"] = { Base64 = true },
    ["cn.hutool.crypto.digest"] = { DigestUtil = true },
    ["android.util"] = { Base64 = true },
}

local KNOWN_PACKAGES = {
    java = true,
    ["java.lang"] = true,
    ["java.math"] = true,
    ["java.io"] = true,
    ["java.util"] = true,
    ["java.util.zip"] = true,
    ["java.security"] = true, ["java.security.interfaces"] = true, ["java.security.spec"] = true,
    javax = true, ["javax.crypto"] = true, ["javax.crypto.spec"] = true,
    org = true, ["org.jsoup"] = true, okhttp3 = true,
    cn = true, ["cn.hutool"] = true, ["cn.hutool.core"] = true,
    ["cn.hutool.core.util"] = true, ["cn.hutool.core.codec"] = true,
    ["cn.hutool.crypto"] = true, ["cn.hutool.crypto.digest"] = true,
    android = true, ["android.util"] = true,
}

local function hostError(category, message)
    category = tostring(category or "HOST_API_UNSUPPORTED")
    if category == "HOST_API_UNSUPPORTED" then
        error(category .. ": host-unsupported: " .. tostring(message or "unsupported Java host operation"))
    end
    error(category .. ": " .. tostring(message or "unsupported Java host operation"))
end

local function normalizeEncoding(value)
    value = tostring(value or "UTF-8"):upper():gsub("[_%s%-]", "")
    if value == "UTF8" then return "UTF-8" end
    if value == "ISO88591" or value == "LATIN1" then return "ISO-8859-1" end
    hostError("HOST_API_UNSUPPORTED", "unsupported byte/string encoding " .. value)
end

local function bytesFrom(value, label)
    label = label or "byte array"
    if type(value) == "string" then
        if #value > MAX_BYTES then hostError("HOST_API_LIMIT", label .. " exceeds byte limit") end
        return value
    end
    if type(value) ~= "table" then hostError("HOST_API_INVALID", label .. " is not a byte array") end
    local marker = rawget(value, "kind")
    if marker == "java_byte_array" then
        local bytes = rawget(value, "bytes") or ""
        if #bytes > MAX_BYTES then hostError("HOST_API_LIMIT", label .. " exceeds byte limit") end
        return bytes
    end
    local count = #value
    if count > MAX_BYTES then hostError("HOST_API_LIMIT", label .. " exceeds byte limit") end
    local output = {}
    for index = 1, count do
        local number = tonumber(value[index])
        if not number or number ~= number or number % 1 ~= 0 or number < -128 or number > 255 then
            hostError("HOST_API_INVALID", label .. " contains an invalid byte at " .. tostring(index - 1))
        end
        if number < 0 then number = number + 256 end
        output[index] = string.char(number)
    end
    return table.concat(output)
end

local function byteArray(value)
    return { kind = "java_byte_array", bytes = bytesFrom(value) }
end

local function unsignedBytes(value)
    if type(value) == "table" and value.kind == "BigInteger" then return value.bytes or "" end
    if type(value) == "number" then
        if value < 0 or value % 1 ~= 0 then hostError("HOST_API_INVALID", "RSA integer must be positive") end
        local output = {}
        repeat table.insert(output, 1, string.char(value % 256)); value = math.floor(value / 256) until value == 0
        return table.concat(output)
    end
    return bytesFrom(value, "RSA integer")
end

local function parseBigInteger(text, radix)
    text, radix = tostring(text or "0"), tonumber(radix or 10)
    if radix ~= 10 and radix ~= 16 then hostError("HOST_API_UNSUPPORTED", "BigInteger radix must be 10 or 16") end
    if text:sub(1, 1) == "-" then hostError("HOST_API_UNSUPPORTED", "negative BigInteger is not supported") end
    text = text:gsub("^%+", "")
    local bytes = { 0 }
    for index = 1, #text do
        local digit = tonumber(text:sub(index, index), radix)
        if digit == nil or digit >= radix then hostError("HOST_API_INVALID", "invalid BigInteger digit") end
        local carry = digit
        for position = #bytes, 1, -1 do
            local value = bytes[position] * radix + carry
            bytes[position], carry = value % 256, math.floor(value / 256)
        end
        while carry > 0 do table.insert(bytes, 1, carry % 256); carry = math.floor(carry / 256) end
    end
    while #bytes > 1 and bytes[1] == 0 do table.remove(bytes, 1) end
    local output = {}
    for index, value in ipairs(bytes) do output[index] = string.char(value) end
    return table.concat(output)
end

local function bigIntegerDecimal(value)
    local work = { tostring(value or ""):byte(1, -1) }
    local digits = {}
    while #work > 0 do
        local quotient, remainder, started = {}, 0, false
        for _, byte in ipairs(work) do
            local current = remainder * 256 + byte
            local part = math.floor(current / 10)
            remainder = current % 10
            if part ~= 0 or started then quotient[#quotient + 1], started = part, true end
        end
        digits[#digits + 1] = tostring(remainder)
        work = quotient
    end
    if #digits == 0 then return "0" end
    local output = {}
    for index = #digits, 1, -1 do output[#output + 1] = digits[index] end
    return table.concat(output)
end

local function byteArrayRange(value, offset, length)
    local bytes = bytesFrom(value)
    offset = tonumber(offset or 0)
    length = tonumber(length)
    if not offset or offset % 1 ~= 0 or offset < 0 then hostError("HOST_API_INVALID", "negative byte-array offset") end
    if length == nil then length = #bytes - offset end
    if length % 1 ~= 0 or length < 0 or offset + length > #bytes then
        hostError("HOST_API_INVALID", "byte-array range is outside its bounds")
    end
    return bytes, offset, length
end

local function writeBytes(target, offset, value, value_offset, length)
    if target.closed then hostError("HOST_API_STATE", "stream is closed") end
    local source, source_offset, source_length = byteArrayRange(value, value_offset, length)
    offset = tonumber(offset or 0)
    if not offset or offset % 1 ~= 0 or offset < 0 then hostError("HOST_API_INVALID", "negative output offset") end
    local old = target.bytes or ""
    if offset > #old then old = old .. string.rep("\0", offset - #old) end
    local end_at = offset + source_length
    if end_at > MAX_BYTES then hostError("HOST_API_LIMIT", "byte-array output exceeds safety limit") end
    local prefix = old:sub(1, offset)
    local suffix = old:sub(end_at + 1)
    target.bytes = prefix .. source:sub(source_offset + 1, source_offset + source_length) .. suffix
end

local function inputRead(stream)
    if stream.closed then hostError("HOST_API_STATE", "stream is closed") end
    local remaining = #stream.bytes - stream.position
    if remaining <= 0 then return -1 end
    stream.position = stream.position + 1
    return string.byte(stream.bytes, stream.position)
end

-- The buffer writer is kept separate from inputRead so it can mutate an
-- opaque Java byte-array object without exposing Lua tables to JavaScript.
local function fillInputBuffer(stream, buffer, offset, length)
    if stream.closed then hostError("HOST_API_STATE", "stream is closed") end
    if type(buffer) ~= "table" or rawget(buffer, "kind") ~= "java_byte_array" then
        hostError("HOST_API_INVALID", "read(buffer) requires a Java byte array")
    end
    offset = tonumber(offset or 0)
    length = tonumber(length)
    if not offset or offset % 1 ~= 0 or offset < 0 then hostError("HOST_API_INVALID", "negative read offset") end
    local current = buffer.bytes or ""
    if length == nil then length = #current - offset end
    if length % 1 ~= 0 or length < 0 or offset + length > #current then
        hostError("HOST_API_INVALID", "read buffer range is outside its bounds")
    end
    local remaining = #stream.bytes - stream.position
    if remaining <= 0 then return -1 end
    local count = math.min(remaining, length)
    buffer.bytes = current:sub(1, offset) .. stream.bytes:sub(stream.position + 1, stream.position + count)
        .. current:sub(offset + count + 1)
    stream.position = stream.position + count
    return count
end

local function decodeString(bytes, encoding)
    encoding = normalizeEncoding(encoding)
    if encoding == "UTF-8" then return bytes end
    local output = {}
    for index = 1, #bytes do output[index] = string.char(string.byte(bytes, index)) end
    return table.concat(output)
end

local function textFrom(value)
    if type(value) == "table" then
        local kind = rawget(value, "kind")
        if kind == "JavaString" then return tostring(rawget(value, "value") or "") end
        if kind == "java_byte_array" then return decodeString(rawget(value, "bytes") or "", "UTF-8") end
    end
    return tostring(value or "")
end

function JavaHostCompat:isKnownPackage(path)
    return KNOWN_PACKAGES[tostring(path or "")] == true
end

function JavaHostCompat:resolve(path)
    path = tostring(path or ""):gsub("^Packages\\.", "")
    if KNOWN_PACKAGES[path] then return { kind = "package", name = path } end
    local package_name, class_name = path:match("^(.*)%.([^.]+)$")
    if package_name and PACKAGE_CLASSES[package_name] and PACKAGE_CLASSES[package_name][class_name] then
        return { kind = "class", name = path }
    end
    hostError("HOST_API_UNSUPPORTED", "Java package/class is not allowlisted: " .. path)
end

function JavaHostCompat:importPackage(path)
    path = tostring(path or "")
    if not KNOWN_PACKAGES[path] then
        hostError("HOST_API_UNSUPPORTED", "Java package is not allowlisted: " .. path)
    end
    local classes = {}
    for class_name in pairs(PACKAGE_CLASSES[path] or {}) do classes[#classes + 1] = class_name end
    table.sort(classes)
    return classes
end

function JavaHostCompat:construct(class_name, args)
    class_name = tostring(class_name or "")
    args = args or {}
    if class_name == "java.io.ByteArrayInputStream" then
        local bytes = bytesFrom(args[1], "ByteArrayInputStream input")
        return { kind = "ByteArrayInputStream", bytes = bytes, position = 0, closed = false }
    elseif class_name == "java.io.ByteArrayOutputStream" then
        local size = tonumber(args[1] or 0) or 0
        if size < 0 or size > MAX_BYTES then hostError("HOST_API_LIMIT", "ByteArrayOutputStream initial size exceeds limit") end
        return { kind = "ByteArrayOutputStream", bytes = "", closed = false }
    elseif class_name == "java.util.zip.GZIPInputStream" then
        local input = args[1]
        if type(input) ~= "table" or rawget(input, "kind") ~= "ByteArrayInputStream" then
            hostError("HOST_API_INVALID", "GZIPInputStream requires ByteArrayInputStream")
        end
        if input.closed then hostError("HOST_API_STATE", "input stream is closed") end
        local compressed = input.bytes:sub(input.position + 1)
        if #compressed > MAX_GZIP_INPUT then hostError("HOST_API_LIMIT", "gzip input exceeds safety limit") end
        local output, err = CompressionCompat:gunzip(compressed, {
            max_input = MAX_GZIP_INPUT,
            max_output = MAX_GZIP_OUTPUT,
            max_ratio = MAX_GZIP_RATIO,
        })
        if not output then hostError("GZIP_DATA_ERROR", err or "invalid gzip data") end
        input.position = #input.bytes
        return { kind = "GZIPInputStream", bytes = output, position = 0, closed = false }
    elseif class_name == "java.lang.String" then
        local value = args[1]
        if type(value) == "table" and rawget(value, "kind") == "java_byte_array" then
            value = decodeString(value.bytes or "", args[2])
        else
            value = tostring(value or "")
        end
        return { kind = "JavaString", value = value, closed = false }
    elseif class_name == "java.math.BigInteger" then
        local value
        if type(args[1]) == "number" and args[2] ~= nil then
            if tonumber(args[1]) ~= 1 then hostError("HOST_API_UNSUPPORTED", "only positive BigInteger byte arrays are supported") end
            value = bytesFrom(args[2], "BigInteger bytes"):gsub("^\0+", "")
        elseif type(args[1]) == "table" then
            value = bytesFrom(args[1], "BigInteger bytes"):gsub("^\0+", "")
        else
            value = parseBigInteger(args[1], args[2])
        end
        return { kind = "BigInteger", bytes = value ~= "" and value or "\0" }
    elseif class_name == "java.util.Base64" then
        hostError("HOST_API_INVALID", "Base64 is a static utility and cannot be constructed")
    elseif class_name == "java.security.spec.PKCS8EncodedKeySpec" then
        return { kind = "PKCS8EncodedKeySpec", bytes = bytesFrom(args[1], "PKCS8 key") }
    elseif class_name == "java.security.spec.X509EncodedKeySpec" then
        return { kind = "X509EncodedKeySpec", bytes = bytesFrom(args[1], "X509 key") }
    elseif class_name == "java.security.spec.RSAPublicKeySpec" then
        return { kind = "RSAPublicKeySpec", modulus = args[1], exponent = args[2] }
    elseif class_name == "javax.crypto.spec.SecretKeySpec" then
        return { kind = "SecretKeySpec", bytes = bytesFrom(args[1], "secret key"), algorithm = tostring(args[2] or "AES") }
    elseif class_name == "javax.crypto.spec.IvParameterSpec" then
        return { kind = "IvParameterSpec", bytes = bytesFrom(args[1], "initialization vector") }
    elseif class_name == "okhttp3.OkHttpClient" then
        return { kind = "OkHttpClient" }
    elseif class_name == "okhttp3.Request.Builder" then
        return { kind = "OkHttpRequestBuilder", method = "GET", headers = {} }
    elseif class_name == "okhttp3.RequestBody" or class_name == "okhttp3.MediaType" then
        hostError("HOST_API_INVALID", class_name:match("([^.]+)$") .. " is a static utility and cannot be constructed")
    elseif class_name == "okhttp3.Headers" then
        return { kind = "OkHttpHeaders", values = {} }
    end
    hostError("HOST_API_UNSUPPORTED", "Java constructor is not allowlisted: " .. class_name)
end

function JavaHostCompat:static(class_name, method, args)
    class_name, method, args = tostring(class_name or ""), tostring(method or ""), args or {}
    if class_name == "java.util.Base64" and method == "getDecoder" then
        return { kind = "Base64Decoder", closed = false }
    end
    if (class_name == "java.security.KeyFactory" or class_name == "java.security.Signature"
            or class_name == "javax.crypto.Cipher" or class_name == "javax.crypto.Mac")
            and method == "getInstance" then
        return { kind = class_name:match("([^.]+)$"), algorithm = tostring(args[1] or "") }
    end
    if class_name == "java.util.Arrays" and method == "copyOfRange" then
        local from, to = tonumber(args[2]), tonumber(args[3])
        if from == nil or to == nil then hostError("HOST_API_INVALID", "Arrays.copyOfRange requires from and to") end
        local bytes, offset, length = byteArrayRange(args[1], from, to - from)
        return byteArray(bytes:sub(offset + 1, offset + length))
    end
    if class_name == "java.util.UUID" and method == "randomUUID" then
        local Crypto = require("Leko/CryptoCompat")
        return { kind = "UUID", value = Crypto:randomUUID() }
    end
    if class_name == "java.lang.System" and method == "currentTimeMillis" then return math.floor(os.time() * 1000) end
    if class_name == "okhttp3.MediaType" and method == "parse" then return { kind = "OkHttpMediaType", value = tostring(args[1] or "") } end
    if class_name == "org.jsoup.Jsoup" and method == "connect" then return { kind = "JsoupConnection", url = tostring(args[1] or ""), method = "GET", headers = {} } end
    if class_name == "okhttp3.RequestBody" and method == "create" then
        return { kind = "OkHttpRequestBody", body = bytesFrom(args[1] or "", "request body"), media_type = args[2] }
    end
    if class_name == "cn.hutool.core.codec.Base64" and (method == "encode" or method == "decode") then
        local Crypto = require("Leko/CryptoCompat")
        return method == "encode" and Crypto.base64Encode(args[1]) or Crypto.base64Decode(args[1])
    end
    if class_name == "android.util.Base64" and method == "encodeToString" then return require("Leko/CryptoCompat").base64Encode(args[1]) end
    if class_name == "android.util.Base64" and method == "decode" then return require("Leko/CryptoCompat").base64Decode(args[1]) end
    if class_name == "cn.hutool.crypto.digest.DigestUtil" and method == "md5Hex" then return require("Leko/Digest"):md5(args[1]) end
    if class_name == "cn.hutool.core.util.StrUtil" and method == "reverse" then return tostring(args[1] or ""):reverse() end
    if class_name == "cn.hutool.core.util.ZipUtil" and method == "gzip" then
        local output, err = CompressionCompat:gzip(tostring(args[1] or ""))
        if not output then hostError("GZIP_DATA_ERROR", err or "gzip failed") end
        return byteArray(output)
    end
    if (class_name == "javax.crypto.Mac" or class_name == "javax.crypto.Cipher") and method == "getInstance" then
        return { kind = class_name:match("([^.]+)$"), algorithm = tostring(args[1] or "") }
    end
    hostError("HOST_API_UNSUPPORTED", "Java static method is not allowlisted: " .. class_name .. "." .. method)
end

function JavaHostCompat:method(object, method, args)
    method, args = tostring(method or ""), args or {}
    local kind = type(object) == "table" and rawget(object, "kind") or ""
    if kind == "ByteArrayInputStream" or kind == "GZIPInputStream" then
        if method == "read" then
            if #args == 0 then return inputRead(object) end
            return fillInputBuffer(object, args[1], args[2], args[3])
        elseif method == "available" then
            if object.closed then hostError("HOST_API_STATE", "stream is closed") end
            return math.max(0, #object.bytes - object.position)
        elseif method == "close" then
            -- ByteArrayInputStream.close() is specified as a no-op in the
            -- JDK; GZIPInputStream.close() really closes its stream.
            if kind == "GZIPInputStream" then object.closed = true end
            return nil
        elseif method == "toString" then
            return "java.io.InputStream"
        end
    elseif kind == "ByteArrayOutputStream" then
        if method == "write" then
            if #args == 0 then hostError("HOST_API_INVALID", "write requires bytes") end
            if #args == 1 and type(args[1]) == "number" then
                if object.closed then hostError("HOST_API_STATE", "stream is closed") end
                local number = tonumber(args[1])
                if number < 0 or number > 255 or number % 1 ~= 0 then hostError("HOST_API_INVALID", "write byte is outside 0..255") end
                if #(object.bytes or "") >= MAX_BYTES then hostError("HOST_API_LIMIT", "byte-array output exceeds safety limit") end
                object.bytes = (object.bytes or "") .. string.char(number)
            else
                -- OutputStream.write(byte[], off, len) appends to the output;
                -- the offset/length belong to the input byte array.
                writeBytes(object, #(object.bytes or ""), args[1], args[2], args[3])
            end
            return nil
        elseif method == "toByteArray" then
            if object.closed then hostError("HOST_API_STATE", "stream is closed") end
            return byteArray(object.bytes or "")
        elseif method == "toString" then
            if object.closed then hostError("HOST_API_STATE", "stream is closed") end
            return decodeString(object.bytes or "", args[1])
        elseif method == "size" then
            return #(object.bytes or "")
        elseif method == "close" then
            -- ByteArrayOutputStream.close() is also a no-op in Java.  Rules
            -- commonly close it before calling toString()/toByteArray().
            return nil
        end
    elseif kind == "Base64Decoder" then
        if method == "decode" then
            local Crypto = require("Leko/CryptoCompat")
            -- In an imported `with (javaImport)` scope, `String(value)` is
            -- the allowlisted Java String constructor, not JavaScript's
            -- native String function.  Legado's Base64 decoder accepts that
            -- Java String directly, so unwrap it at this host boundary.
            local text = textFrom(args[1])
            if #text > MAX_BYTES * 2 then hostError("HOST_API_LIMIT", "Base64 input exceeds safety limit") end
            local ok, decoded = pcall(Crypto.base64Decode, text)
            if not ok or type(decoded) ~= "string" then hostError("HOST_API_INVALID", "invalid Base64 input") end
            return byteArray(decoded)
        end
    elseif kind == "JavaString" then
        if method == "getBytes" then
            normalizeEncoding(args[1])
            return byteArray(object.value or "")
        elseif method == "toString" then return object.value or "" end
    elseif kind == "BigInteger" then
        if method == "toByteArray" then
            local value = object.bytes or "\0"
            if value:byte(1) >= 0x80 then value = "\0" .. value end
            return byteArray(value)
        elseif method == "toString" then
            local radix = tonumber(args[1] or 10)
            if radix == 16 then
                local value = ((object.bytes or ""):gsub(".", function(char) return string.format("%02x", char:byte()) end)):gsub("^0+", "")
                return value ~= "" and value or "0"
            end
            if radix == 10 then return bigIntegerDecimal(object.bytes) end
            hostError("HOST_API_UNSUPPORTED", "BigInteger.toString radix must be 10 or 16")
        end
    elseif kind == "UUID" then
        if method == "toString" then return object.value end
    elseif kind == "JavaMap" then
        local values = object.values or {}
        if method == "get" then
            local key = tostring(args[1] or "")
            return values[key] or values[key:lower()]
        elseif method == "containsKey" then
            local key = tostring(args[1] or "")
            return values[key] ~= nil or values[key:lower()] ~= nil
        elseif method == "isEmpty" then return next(values) == nil end
        if method == "toString" then
            local output = {}
            for key, value in pairs(values) do output[#output + 1] = tostring(key) .. "=" .. tostring(value) end
            table.sort(output)
            return "{" .. table.concat(output, ", ") .. "}"
        end
    elseif kind == "KeyFactory" then
        if method == "generatePrivate" and type(args[1]) == "table" and args[1].kind == "PKCS8EncodedKeySpec" then
            return { kind = "RSAPrivateKey", bytes = args[1].bytes, algorithm = object.algorithm }
        elseif method == "generatePublic" and type(args[1]) == "table" and args[1].kind == "X509EncodedKeySpec" then
            return { kind = "RSAPublicKey", bytes = args[1].bytes, algorithm = object.algorithm }
        elseif method == "generatePublic" and type(args[1]) == "table" and args[1].kind == "RSAPublicKeySpec" then
            return {
                kind = "RSAPublicKey", modulus = unsignedBytes(args[1].modulus),
                exponent = unsignedBytes(args[1].exponent), algorithm = object.algorithm,
            }
        end
    elseif kind == "Signature" then
        if method == "initSign" then object.key, object.data = args[1], ""; return nil end
        if method == "initVerify" then object.key, object.data = args[1], ""; return nil end
        if method == "update" then object.data = (object.data or "") .. bytesFrom(args[1], "signature data"); return nil end
        if method == "sign" and type(object.key) == "table" and object.key.kind == "RSAPrivateKey" then
            local result, err = require("Leko/CryptoCompat"):rsaSign(object.key.bytes, object.data or "", object.algorithm)
            if not result then hostError("CRYPTO_ERROR", err or "RSA signing failed") end
            return byteArray(result)
        elseif method == "verify" and type(object.key) == "table" and object.key.kind == "RSAPublicKey" then
            local Crypto = require("Leko/CryptoCompat")
            local signature = bytesFrom(args[1], "RSA signature")
            local verified, err
            if object.key.bytes then
                verified, err = Crypto:rsaVerify(object.key.bytes, object.data or "", signature, object.algorithm)
            else
                verified, err = Crypto:rsaVerifyComponents(
                    object.key.modulus, object.key.exponent, object.data or "", signature, object.algorithm)
            end
            if verified == nil then hostError("CRYPTO_ERROR", err or "RSA verification failed") end
            return verified
        end
    elseif kind == "Cipher" then
        if method == "init" then
            local mode, key, iv = tonumber(args[1]) or 2, args[2] or {}, args[3]
            if tostring(object.algorithm or ""):upper():match("^RSA") then
                if type(key) ~= "table" or (key.kind ~= "RSAPublicKey" and key.kind ~= "RSAPrivateKey") then
                    hostError("HOST_API_INVALID", "RSA Cipher.init requires an RSA key")
                end
                object.key, object.encrypt, object.crypto = key, mode ~= 2, nil
                return nil
            end
            if type(key) ~= "table" or key.kind ~= "SecretKeySpec" then hostError("HOST_API_INVALID", "Cipher.init requires SecretKeySpec") end
            if iv ~= nil and (type(iv) ~= "table" or iv.kind ~= "IvParameterSpec") then
                hostError("HOST_API_INVALID", "Cipher.init IV must be IvParameterSpec")
            end
            object.crypto = require("Leko/CryptoCompat"):createSymmetricCrypto(
                object.algorithm, key.bytes, iv and iv.bytes or "")
            object.encrypt = mode ~= 2
            return nil
        elseif method == "doFinal" and object.key and tostring(object.algorithm or ""):upper():match("^RSA") then
            local input = bytesFrom(args[1], "RSA cipher input")
            local Crypto = require("Leko/CryptoCompat")
            local result, err
            if object.encrypt and object.key.kind == "RSAPublicKey" then
                if object.key.bytes then result, err = Crypto:rsaPublicEncrypt(object.key.bytes, input, object.algorithm)
                else result, err = Crypto:rsaPublicEncryptComponents(object.key.modulus, object.key.exponent, input, object.algorithm) end
            elseif not object.encrypt and object.key.kind == "RSAPrivateKey" then
                result, err = Crypto:rsaPrivateDecrypt(object.key.bytes, input, object.algorithm)
            else
                hostError("HOST_API_UNSUPPORTED", "only RSA public-encrypt/private-decrypt is supported")
            end
            if not result then hostError("CRYPTO_ERROR", err or "RSA cipher failed") end
            return byteArray(result)
        elseif method == "doFinal" and object.crypto then
            local input = bytesFrom(args[1], "cipher input")
            return byteArray(object.encrypt and object.crypto:encrypt(input) or object.crypto:decrypt(input))
        end
    elseif kind == "Mac" then
        if method == "init" then
            local key = args[1]
            if type(key) ~= "table" or key.kind ~= "SecretKeySpec" then hostError("HOST_API_INVALID", "Mac.init requires SecretKeySpec") end
            object.key, object.data = key.bytes, ""
            return nil
        elseif method == "update" then
            object.data = (object.data or "") .. bytesFrom(args[1], "HMAC data")
            return nil
        elseif method == "doFinal" then
            local extra = args[1] and bytesFrom(args[1], "HMAC data") or ""
            local result, err = require("Leko/Digest"):hmacBinary((object.data or "") .. extra, object.algorithm, object.key or "")
            if not result then hostError("CRYPTO_ERROR", err or "HMAC failed") end
            object.data = ""
            return byteArray(result)
        end
    elseif kind == "OkHttpRequestBuilder" then
        if method == "url" then object.url = tostring(args[1] or ""); return object end
        if method == "get" then object.method, object.body = "GET", nil; return object end
        if method == "post" or method == "put" or method == "delete" then object.method, object.body = method:upper(), args[1]; return object end
        if method == "addHeader" or method == "header" then object.headers[tostring(args[1] or "")] = tostring(args[2] or ""); return object end
        if method == "build" then return { kind = "OkHttpRequest", url = object.url or "", method = object.method or "GET", body = object.body, headers = object.headers or {} } end
    elseif kind == "OkHttpClient" then
        if method == "newCall" then return { kind = "OkHttpCall", request = args[1] } end
    elseif kind == "OkHttpRequest" then
        if method == "url" then return object.url end
        if method == "method" then return object.method end
        if method == "body" then return object.body end
    elseif kind == "OkHttpCall" then
        if method == "request" then return object.request end
    elseif kind == "JsoupConnection" then
        if method == "userAgent" or method == "header" or method == "referrer" then object.headers[tostring(args[1] or "")] = tostring(args[2] or ""); return object end
        if method == "ignoreContentType" or method == "followRedirects" or method == "ignoreHttpErrors" then object[method] = args[1] == true; return object end
        if method == "method" then object.method = tostring(args[1] or "GET"); return object end
        if method == "requestBody" or method == "data" then object.body = tostring(args[2] or args[1] or ""); return object end
    end
    hostError("HOST_API_UNSUPPORTED", "Java object method is not allowlisted: " .. kind .. "." .. method)
end

function JavaHostCompat:handleProperty(object, property)
    local kind = type(object) == "table" and rawget(object, "kind") or ""
    property = tostring(property or "")
    if kind == "java_byte_array" then
        if property == "length" then return #(object.bytes or "") end
        local index = tonumber(property)
        if index and index % 1 == 0 then
            index = index + 1
            return index >= 1 and index <= #(object.bytes or "") and string.byte(object.bytes, index) or nil
        end
    end
    return nil
end

function JavaHostCompat:limits()
    return {
        max_bytes = MAX_BYTES,
        max_gzip_input = MAX_GZIP_INPUT,
        max_gzip_output = MAX_GZIP_OUTPUT,
        max_gzip_ratio = MAX_GZIP_RATIO,
    }
end

return JavaHostCompat
