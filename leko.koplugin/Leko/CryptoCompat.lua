-- Legado-compatible digest and symmetric-crypto helpers.
-- On KOReader/LuaJIT this uses the libcrypto already shipped by KOReader.
-- Desktop package tests fall back to the openssl command when FFI is absent.
local Digest = require("Leko/Digest")

local CryptoCompat = {}
local mime_ok, mime = pcall(require, "mime")

local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- LuaSocket variants bundled by readers have not always exposed identical
-- wrappers around mime.core.  Accept the native path only after a tiny
-- conformance check, and normalize wrapped output before it reaches a data:
-- URI or an aggregate authentication header.
local native_b64, native_unb64
if mime_ok and mime and type(mime.b64) == "function" and type(mime.unb64) == "function" then
    local ok_encode, encoded = pcall(mime.b64, "Leko")
    local ok_decode, decoded = pcall(mime.unb64, "TGVrbw==")
    encoded = ok_encode and tostring(encoded or ""):gsub("%s+", "") or ""
    if encoded == "TGVrbw==" and ok_decode and decoded == "Leko" then
        native_b64, native_unb64 = mime.b64, mime.unb64
    end
end

local function hex(value)
    return (tostring(value or ""):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function unhex(value)
    value = tostring(value or ""):gsub("%s", "")
    if #value % 2 ~= 0 or value:find("[^%x]") then return nil, "invalid hex" end
    return (value:gsub("(%x%x)", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function base64Encode(data)
    data = tostring(data or "")
    if native_b64 then
        local ok, encoded = pcall(native_b64, data)
        if ok and encoded ~= nil then return (tostring(encoded):gsub("%s+", "")) end
    end
    -- Desktop source-lab builds do not ship LuaSocket's native mime module.
    -- Keep a compact arithmetic fallback there; KOReader/Kindle uses mime.b64.
    local output = {}
    for index = 1, #data, 3 do
        local a, b, c = data:byte(index, index + 2)
        local value = a * 65536 + (b or 0) * 256 + (c or 0)
        output[#output + 1] = BASE64:sub(math.floor(value / 262144) % 64 + 1, math.floor(value / 262144) % 64 + 1)
        output[#output + 1] = BASE64:sub(math.floor(value / 4096) % 64 + 1, math.floor(value / 4096) % 64 + 1)
        output[#output + 1] = b and BASE64:sub(math.floor(value / 64) % 64 + 1, math.floor(value / 64) % 64 + 1) or "="
        output[#output + 1] = c and BASE64:sub(value % 64 + 1, value % 64 + 1) or "="
    end
    return table.concat(output)
end

local function base64Decode(data)
    -- java.util.Base64 decoders used by imported sources commonly receive
    -- URL-safe ciphertext as well as ordinary Base64.  Accept both alphabets;
    -- whitespace is still ignored just like Android's MIME-capable decoder.
    data = tostring(data or ""):gsub("%-", "+"):gsub("_", "/"):gsub("%s", "")
    data = data:gsub("[^" .. BASE64 .. "=]", "")
    data = data:gsub("=+$", "")
    local remainder = #data % 4
    if remainder == 2 then data = data .. "==" elseif remainder == 3 then data = data .. "=" end
    if native_unb64 then
        local ok, decoded = pcall(native_unb64, data)
        if ok and decoded ~= nil then return decoded end
    end
    local output = {}
    for index = 1, #data, 4 do
        local a = (BASE64:find(data:sub(index, index), 1, true) or 1) - 1
        local b = (BASE64:find(data:sub(index + 1, index + 1), 1, true) or 1) - 1
        local c_char, d_char = data:sub(index + 2, index + 2), data:sub(index + 3, index + 3)
        local c = c_char == "=" and 0 or ((BASE64:find(c_char, 1, true) or 1) - 1)
        local d = d_char == "=" and 0 or ((BASE64:find(d_char, 1, true) or 1) - 1)
        local value = a * 262144 + b * 4096 + c * 64 + d
        output[#output + 1] = string.char(math.floor(value / 65536) % 256)
        if c_char ~= "=" and c_char ~= "" then output[#output + 1] = string.char(math.floor(value / 256) % 256) end
        if d_char ~= "=" and d_char ~= "" then output[#output + 1] = string.char(value % 256) end
    end
    return table.concat(output)
end

CryptoCompat.hex = hex
CryptoCompat.unhex = unhex
CryptoCompat.base64Encode = base64Encode
CryptoCompat.base64Decode = base64Decode

local ffi_ok, ffi = pcall(require, "ffi")
local libcrypto
if ffi_ok then
    pcall(function()
        ffi.cdef[[
            typedef struct engine_st ENGINE;
            typedef struct evp_cipher_st EVP_CIPHER;
            typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
            EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
            void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *);
            int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *, int);
            int EVP_CIPHER_block_size(const EVP_CIPHER *);
            int EVP_CIPHER_get_block_size(const EVP_CIPHER *);
            int EVP_EncryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
            int EVP_EncryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
            int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
            int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
            int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
            int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
            const EVP_CIPHER *EVP_aes_128_cbc(void);
            const EVP_CIPHER *EVP_aes_192_cbc(void);
            const EVP_CIPHER *EVP_aes_256_cbc(void);
            const EVP_CIPHER *EVP_aes_128_ecb(void);
            const EVP_CIPHER *EVP_aes_192_ecb(void);
            const EVP_CIPHER *EVP_aes_256_ecb(void);
            const EVP_CIPHER *EVP_des_cbc(void);
            const EVP_CIPHER *EVP_des_ecb(void);
            const EVP_CIPHER *EVP_des_ede3_cbc(void);
            const EVP_CIPHER *EVP_des_ede3_ecb(void);
            typedef struct evp_pkey_st EVP_PKEY;
            typedef struct evp_md_ctx_st EVP_MD_CTX;
            typedef struct evp_pkey_ctx_st EVP_PKEY_CTX;
            typedef struct evp_md_st EVP_MD;
            typedef struct rsa_st RSA;
            EVP_PKEY *d2i_AutoPrivateKey(EVP_PKEY **, const unsigned char **, long);
            EVP_PKEY *d2i_PUBKEY(EVP_PKEY **, const unsigned char **, long);
            void EVP_PKEY_free(EVP_PKEY *);
            RSA *EVP_PKEY_get1_RSA(EVP_PKEY *);
            RSA *d2i_RSA_PUBKEY(RSA **, const unsigned char **, long);
            RSA *d2i_RSAPublicKey(RSA **, const unsigned char **, long);
            void RSA_free(RSA *);
            int RSA_size(const RSA *);
            int RSA_public_encrypt(int, const unsigned char *, unsigned char *, RSA *, int);
            int RSA_private_decrypt(int, const unsigned char *, unsigned char *, RSA *, int);
            int RSA_verify(int, const unsigned char *, unsigned int, const unsigned char *, unsigned int, RSA *);
            EVP_MD_CTX *EVP_MD_CTX_new(void);
            void EVP_MD_CTX_free(EVP_MD_CTX *);
            EVP_MD_CTX *EVP_MD_CTX_create(void);
            void EVP_MD_CTX_destroy(EVP_MD_CTX *);
            const EVP_MD *EVP_sha256(void);
            const EVP_MD *EVP_sha1(void);
            const EVP_MD *EVP_md5(void);
            int EVP_DigestSignInit(EVP_MD_CTX *, EVP_PKEY_CTX **, const EVP_MD *, ENGINE *, EVP_PKEY *);
            int EVP_DigestSignUpdate(EVP_MD_CTX *, const void *, size_t);
            int EVP_DigestSignFinal(EVP_MD_CTX *, unsigned char *, size_t *);
        ]]
        local candidates = {}
        if type(ffi.loadlib) == "function" then
            for _, version in ipairs({ "57", "3", "1.1", "1.0.0" }) do
                local ok, loaded = pcall(ffi.loadlib, "crypto", version)
                if ok and loaded then candidates[#candidates + 1] = loaded end
            end
        end
        for _, name in ipairs({ "crypto", "libcrypto.so", "libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so.57", "libcrypto-3-x64" }) do
            local ok, loaded = pcall(ffi.load, name)
            if ok and loaded then candidates[#candidates + 1] = loaded end
        end
        for _, candidate in ipairs(candidates) do
            -- A SONAME match alone is not an ABI contract. LibreSSL/OpenSSL
            -- variants found on older KOReader/Kindle builds may expose the
            -- context constructor but omit a later EVP symbol; selecting such
            -- a library used to turn an AES TOC rule into a hard LuaJIT error.
            local ok = pcall(function()
                return candidate.EVP_CIPHER_CTX_new,
                    candidate.EVP_CIPHER_CTX_free,
                    candidate.EVP_CIPHER_CTX_set_padding,
                    candidate.EVP_EncryptInit_ex, candidate.EVP_EncryptUpdate,
                    candidate.EVP_EncryptFinal_ex, candidate.EVP_DecryptInit_ex,
                    candidate.EVP_DecryptUpdate, candidate.EVP_DecryptFinal_ex,
                    candidate.EVP_aes_128_cbc
            end)
            if ok then libcrypto = candidate break end
        end
    end)
end

local function normalizeTransformation(value)
    local original = tostring(value or "AES/CBC/PKCS5Padding")
    local upper = original:upper():gsub("PKCS7PADDING", "PKCS5PADDING")
    local algorithm, mode, padding = upper:match("^%s*([%w%-]+)%s*/%s*([%w%-]+)%s*/%s*([%w%-]+)%s*$")
    if not algorithm then algorithm, mode, padding = upper:match("^%s*([%w%-]+)%s*/%s*([%w%-]+)%s*$") end
    algorithm = algorithm or upper:match("^%s*([%w%-]+)") or "AES"
    mode = mode or "ECB"
    padding = padding or "PKCS5PADDING"
    return algorithm, mode, padding
end

local function cipherName(transformation, key_length)
    local algorithm, mode, padding = normalizeTransformation(transformation)
    local no_padding = padding == "NOPADDING"
    if algorithm == "AES" then
        if key_length ~= 16 and key_length ~= 24 and key_length ~= 32 then
            return nil, nil, "AES key must be 16, 24, or 32 bytes"
        end
        return string.format("EVP_aes_%d_%s", key_length * 8, mode:lower()), no_padding
    elseif algorithm == "DES" then
        if key_length ~= 8 then return nil, nil, "DES key must be 8 bytes" end
        return "EVP_des_" .. mode:lower(), no_padding
    elseif algorithm == "DESEDE" or algorithm == "3DES" or algorithm == "TRIPLEDES" then
        if key_length ~= 24 then return nil, nil, "3DES key must be 24 bytes" end
        return "EVP_des_ede3_" .. mode:lower(), no_padding
    end
    return nil, nil, "unsupported cipher " .. algorithm
end

local function pureCipher(encrypt, transformation, input, key, iv)
    local algorithm, mode, padding = normalizeTransformation(transformation)
    local supported = algorithm == "AES" or algorithm == "DES" or algorithm == "DESEDE"
        or algorithm == "3DES" or algorithm == "TRIPLEDES"
    if not supported then return nil, "unsupported cipher " .. algorithm end
    local ok, PureCrypto = pcall(require, "Leko/PureCrypto")
    if not ok or not PureCrypto then return nil, "pure crypto fallback unavailable" end
    if encrypt then return PureCrypto:encrypt(algorithm, input, key, iv, mode, padding) end
    return PureCrypto:decrypt(algorithm, input, key, iv, mode, padding)
end

local function ffiCipher(transformation, key)
    if not libcrypto then return nil, nil, "libcrypto unavailable" end
    local name, no_padding, err = cipherName(transformation, #key)
    if not name then return nil, nil, err end
    local ok, fn = pcall(function() return libcrypto[name] end)
    if not ok or fn == nil then return nil, nil, "cipher unavailable: " .. name end
    local ok_call, cipher = pcall(fn)
    if not ok_call or cipher == nil then return nil, nil, "cipher unavailable: " .. name end
    return cipher, no_padding
end

local function cryptFFI(encrypt, transformation, input, key, iv)
    local cipher, no_padding, err = ffiCipher(transformation, key)
    if not cipher then return nil, err end
    local context = libcrypto.EVP_CIPHER_CTX_new()
    if context == nil then return nil, "EVP context allocation failed" end
    local function finish(value, error_message)
        libcrypto.EVP_CIPHER_CTX_free(context)
        return value, error_message
    end
    local init = encrypt and libcrypto.EVP_EncryptInit_ex or libcrypto.EVP_DecryptInit_ex
    local update = encrypt and libcrypto.EVP_EncryptUpdate or libcrypto.EVP_DecryptUpdate
    local final = encrypt and libcrypto.EVP_EncryptFinal_ex or libcrypto.EVP_DecryptFinal_ex
    local iv_pointer = (iv and iv ~= "") and iv or nil
    if init(context, cipher, nil, key, iv_pointer) ~= 1 then return finish(nil, "cipher init failed") end
    if libcrypto.EVP_CIPHER_CTX_set_padding(context, no_padding and 0 or 1) ~= 1 then
        return finish(nil, "padding setup failed")
    end
    local block_size = 16
    local ok_size, size = pcall(function()
        local ok_old, old_size = pcall(function() return libcrypto.EVP_CIPHER_block_size(cipher) end)
        if ok_old then return old_size end
        return libcrypto.EVP_CIPHER_get_block_size(cipher)
    end)
    if ok_size then block_size = tonumber(size) or block_size end
    local output = ffi.new("unsigned char[?]", #input + block_size * 2)
    local out_len = ffi.new("int[1]")
    if update(context, output, out_len, input, #input) ~= 1 then return finish(nil, "cipher update failed") end
    local total = tonumber(out_len[0])
    local final_len = ffi.new("int[1]")
    if final(context, output + total, final_len) ~= 1 then return finish(nil, "cipher final failed") end
    total = total + tonumber(final_len[0])
    local result = ffi.string(output, total)
    return finish(result)
end

local function shellQuote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function cryptCLI(encrypt, transformation, input, key, iv)
    if type(os.execute) ~= "function" or type(os.tmpname) ~= "function" then return nil, "openssl fallback unavailable" end
    local name, no_padding, err = cipherName(transformation, #key)
    if not name then return nil, err end
    local command_name = name:gsub("^EVP_", ""):gsub("_", "-")
    local input_path, output_path = os.tmpname(), os.tmpname()
    local file = io.open(input_path, "wb")
    if not file then return nil, "temporary file unavailable" end
    file:write(input); file:close()
    local args = { "openssl", "enc", "-" .. command_name, encrypt and "-e" or "-d", "-K", hex(key), "-in", input_path, "-out", output_path }
    if iv and iv ~= "" and not command_name:find("ecb", 1, true) then
        args[#args + 1] = "-iv"
        args[#args + 1] = hex(iv)
    end
    if no_padding then args[#args + 1] = "-nopad" end
    if command_name:find("des", 1, true) then
        args[#args + 1] = "-provider"
        args[#args + 1] = "legacy"
        args[#args + 1] = "-provider"
        args[#args + 1] = "default"
    end
    for index, value in ipairs(args) do args[index] = shellQuote(value) end
    local error_path = os.tmpname()
    local ok = os.execute(table.concat(args, " ") .. " >/dev/null 2>" .. shellQuote(error_path))
    local success = ok == true or ok == 0
    local result = success and readFile(output_path) or nil
    local detail = readFile(error_path)
    os.remove(input_path); os.remove(output_path); os.remove(error_path)
    detail = tostring(detail or ""):gsub("[\r\n]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return result, result and nil or (detail ~= "" and ("openssl cipher failed: " .. detail) or "openssl cipher failed")
end

local function crypt(encrypt, transformation, input, key, iv)
    input, key, iv = tostring(input or ""), tostring(key or ""), tostring(iv or "")
    local result, err
    local algorithm, _, padding = normalizeTransformation(transformation)
    -- EVP has no ZeroPadding switch. Keep that semantic, and all device
    -- fallbacks, in one dependency-free implementation.
    if padding == "ZEROPADDING" then
        result, err = pureCipher(encrypt, transformation, input, key, iv)
    elseif libcrypto then
        local native_ok, native_result, native_error = pcall(
            cryptFFI, encrypt, transformation, input, key, iv)
        if native_ok then result, err = native_result, native_error
        else err = "libcrypto ABI mismatch: " .. tostring(native_result) end
    end
    -- Older Kindle builds may expose AES but omit legacy DES symbols. The
    -- unified fallback covers AES, DES and DESede instead of scattering a
    -- separate implementation beside each bridge entrypoint.
    if result == nil and (algorithm == "AES" or algorithm == "DES" or algorithm == "DESEDE"
            or algorithm == "3DES" or algorithm == "TRIPLEDES") then
        result, err = pureCipher(encrypt, transformation, input, key, iv)
    end
    if result == nil then result, err = cryptCLI(encrypt, transformation, input, key, iv) end
    return result, err
end

local function digestForSignature(algorithm)
    local normalized = tostring(algorithm or "SHA256WithRSA"):upper():gsub("[^A-Z0-9]", "")
    if normalized:find("SHA1", 1, true) then return "sha1", "EVP_sha1", 64 end
    if normalized:find("MD5", 1, true) then return "md5", "EVP_md5", 4 end
    if normalized:find("SHA256", 1, true) then return "sha256", "EVP_sha256", 672 end
    return nil, nil, nil, "unsupported RSA signature algorithm " .. tostring(algorithm)
end

local function rsaSignFFI(private_der, data, algorithm)
    if not libcrypto or not ffi_ok then return nil, "libcrypto unavailable" end
    local _, digest_symbol, _, digest_error = digestForSignature(algorithm)
    if not digest_symbol then return nil, digest_error end
    local required = { "d2i_AutoPrivateKey", "EVP_PKEY_free", digest_symbol, "EVP_DigestSignInit", "EVP_DigestSignUpdate", "EVP_DigestSignFinal" }
    for _, name in ipairs(required) do
        local ok = pcall(function() return libcrypto[name] end)
        if not ok then return nil, "RSA symbol unavailable: " .. name end
    end
    local input = ffi.new("unsigned char[?]", #private_der)
    ffi.copy(input, private_der, #private_der)
    local cursor = ffi.new("const unsigned char *[1]")
    cursor[0] = ffi.cast("const unsigned char *", input)
    local pkey = libcrypto.d2i_AutoPrivateKey(nil, cursor, #private_der)
    if pkey == nil then return nil, "invalid PKCS8 private key" end
    local ctx, free_ctx
    local ok_new, new_fn = pcall(function() return libcrypto.EVP_MD_CTX_new end)
    if ok_new and new_fn ~= nil then
        ctx = new_fn(); free_ctx = function(value) libcrypto.EVP_MD_CTX_free(value) end
    else
        local ok_old, old_fn = pcall(function() return libcrypto.EVP_MD_CTX_create end)
        if ok_old and old_fn ~= nil then ctx = old_fn(); free_ctx = function(value) libcrypto.EVP_MD_CTX_destroy(value) end end
    end
    if ctx == nil then libcrypto.EVP_PKEY_free(pkey); return nil, "EVP digest context unavailable" end
    local function finish(value, err)
        free_ctx(ctx); libcrypto.EVP_PKEY_free(pkey); return value, err
    end
    local digest = libcrypto[digest_symbol]()
    if libcrypto.EVP_DigestSignInit(ctx, nil, digest, nil, pkey) ~= 1 then
        return finish(nil, "RSA sign init failed")
    end
    if libcrypto.EVP_DigestSignUpdate(ctx, data, #data) ~= 1 then
        return finish(nil, "RSA sign update failed")
    end
    local length = ffi.new("size_t[1]")
    if libcrypto.EVP_DigestSignFinal(ctx, nil, length) ~= 1 or tonumber(length[0]) <= 0 then
        return finish(nil, "RSA signature length failed")
    end
    local output = ffi.new("unsigned char[?]", tonumber(length[0]))
    if libcrypto.EVP_DigestSignFinal(ctx, output, length) ~= 1 then
        return finish(nil, "RSA sign final failed")
    end
    return finish(ffi.string(output, tonumber(length[0])))
end

local function rsaSignCLI(private_der, data, algorithm)
    if type(os.execute) ~= "function" or type(os.tmpname) ~= "function" then return nil, "openssl fallback unavailable" end
    local key_path, data_path, sig_path = os.tmpname(), os.tmpname(), os.tmpname()
    local key_file = io.open(key_path, "wb"); if not key_file then return nil, "temporary key unavailable" end
    key_file:write(private_der); key_file:close()
    local data_file = io.open(data_path, "wb"); if not data_file then os.remove(key_path); return nil, "temporary data unavailable" end
    data_file:write(data); data_file:close()
    local digest_name, _, _, digest_error = digestForSignature(algorithm)
    if not digest_name then return nil, digest_error end
    local command = table.concat({ "openssl dgst -" .. digest_name .. " -sign", shellQuote(key_path), "-keyform DER -out", shellQuote(sig_path), shellQuote(data_path), ">/dev/null 2>&1" }, " ")
    local ok = os.execute(command)
    local success = ok == true or ok == 0
    local result = success and readFile(sig_path) or nil
    os.remove(key_path); os.remove(data_path); os.remove(sig_path)
    return result, result and nil or "openssl RSA signing failed"
end

function CryptoCompat:rsaSign(private_der, data, algorithm)
    if type(private_der) == "table" then
        local bytes = {}; for index, value in ipairs(private_der) do bytes[index] = string.char((tonumber(value) or 0) % 256) end
        private_der = table.concat(bytes)
    end
    private_der, data = tostring(private_der or ""), tostring(data or "")
    local result, err = rsaSignFFI(private_der, data, algorithm)
    if not result then result, err = rsaSignCLI(private_der, data, algorithm) end
    return result, err
end

function CryptoCompat:rsaSignSha256(private_der, data)
    return self:rsaSign(private_der, data, "SHA256WithRSA")
end

local function ffiBytes(value)
    local input = ffi.new("unsigned char[?]", #value)
    ffi.copy(input, value, #value)
    local cursor = ffi.new("const unsigned char *[1]")
    cursor[0] = ffi.cast("const unsigned char *", input)
    return input, cursor
end

local function rsaFromPublicDer(public_der)
    if not libcrypto or not ffi_ok then return nil, "libcrypto unavailable" end
    local input, cursor = ffiBytes(public_der)
    local ok_x509, rsa = pcall(function() return libcrypto.d2i_RSA_PUBKEY(nil, cursor, #public_der) end)
    if ok_x509 and rsa ~= nil then return rsa, input end
    input, cursor = ffiBytes(public_der)
    local ok_pkcs1, pkcs1 = pcall(function() return libcrypto.d2i_RSAPublicKey(nil, cursor, #public_der) end)
    if ok_pkcs1 and pkcs1 ~= nil then return pkcs1, input end
    return nil, "invalid X509/PKCS1 RSA public key"
end

local function rsaFromPrivateDer(private_der)
    if not libcrypto or not ffi_ok then return nil, "libcrypto unavailable" end
    local input, cursor = ffiBytes(private_der)
    local ok_decode, pkey = pcall(function()
        return libcrypto.d2i_AutoPrivateKey(nil, cursor, #private_der)
    end)
    if not ok_decode or pkey == nil then return nil, "invalid PKCS8 RSA private key" end
    local ok, rsa = pcall(function() return libcrypto.EVP_PKEY_get1_RSA(pkey) end)
    libcrypto.EVP_PKEY_free(pkey)
    if not ok or rsa == nil then return nil, "private key is not RSA" end
    return rsa, input
end

local function derLength(length)
    if length < 0x80 then return string.char(length) end
    local bytes = {}
    repeat table.insert(bytes, 1, string.char(length % 256)); length = math.floor(length / 256) until length == 0
    return string.char(0x80 + #bytes) .. table.concat(bytes)
end

local function derInteger(value)
    value = tostring(value or ""):gsub("^\0+", "")
    if value == "" then value = "\0" end
    if value:byte(1) >= 0x80 then value = "\0" .. value end
    return string.char(0x02) .. derLength(#value) .. value
end

local function rsaPublicDerFromComponents(modulus, exponent)
    local body = derInteger(modulus) .. derInteger(exponent)
    return string.char(0x30) .. derLength(#body) .. body
end

local function rsaPadding(transformation)
    local value = tostring(transformation or "RSA/ECB/PKCS1Padding"):upper()
    if value == "RSA" then return 1, 11 end
    if value:find("OAEP", 1, true) then
        if value:find("SHA%-?256") then return nil, nil, "RSA OAEP SHA-256 is not supported by the narrow bridge" end
        return 4, 42
    end
    if value:find("NOPADDING", 1, true) then return 3, 0 end
    if value:find("PKCS1PADDING", 1, true) then return 1, 11 end
    return nil, nil, "unsupported RSA padding"
end

local function rsaTransform(rsa, operation, value, transformation)
    local padding, overhead, padding_error = rsaPadding(transformation)
    if not padding then return nil, padding_error end
    local size = tonumber(libcrypto.RSA_size(rsa)) or 0
    if size <= 0 then return nil, "invalid RSA key size" end
    if operation == "encrypt" and #value > size - overhead then return nil, "RSA plaintext is too long" end
    if operation == "encrypt" and padding == 3 and #value ~= size then return nil, "RSA NoPadding input must match key size" end
    if operation == "decrypt" and #value ~= size then return nil, "RSA ciphertext length does not match key" end
    local output = ffi.new("unsigned char[?]", size)
    local length
    if operation == "encrypt" then
        length = libcrypto.RSA_public_encrypt(#value, value, output, rsa, padding)
    else
        length = libcrypto.RSA_private_decrypt(#value, value, output, rsa, padding)
    end
    if tonumber(length) == nil or tonumber(length) < 0 then return nil, "RSA " .. operation .. " failed" end
    return ffi.string(output, tonumber(length))
end

function CryptoCompat:rsaPublicEncrypt(public_der, data, transformation)
    local rsa, keepalive = rsaFromPublicDer(tostring(public_der or ""))
    if not rsa then return nil, keepalive end
    local ok, result, err = pcall(rsaTransform, rsa, "encrypt", tostring(data or ""), transformation)
    libcrypto.RSA_free(rsa)
    if not ok then return nil, "RSA ABI mismatch: " .. tostring(result) end
    return result, err
end

function CryptoCompat:rsaPublicEncryptComponents(modulus, exponent, data, transformation)
    return self:rsaPublicEncrypt(rsaPublicDerFromComponents(modulus, exponent), data, transformation)
end

function CryptoCompat:rsaPrivateDecrypt(private_der, data, transformation)
    local rsa, keepalive = rsaFromPrivateDer(tostring(private_der or ""))
    if not rsa then return nil, keepalive end
    local ok, result, err = pcall(rsaTransform, rsa, "decrypt", tostring(data or ""), transformation)
    libcrypto.RSA_free(rsa)
    if not ok then return nil, "RSA ABI mismatch: " .. tostring(result) end
    return result, err
end

local function rsaVerifyWith(rsa, data, signature, algorithm)
    local digest_name, _, nid, digest_error = digestForSignature(algorithm)
    if not digest_name then return nil, digest_error end
    local digest = Digest:digestBinary(data, digest_name)
    local ok = libcrypto.RSA_verify(nid, digest, #digest, signature, #signature, rsa)
    return tonumber(ok) == 1
end

function CryptoCompat:rsaVerify(public_der, data, signature, algorithm)
    local rsa, keepalive = rsaFromPublicDer(tostring(public_der or ""))
    if not rsa then return nil, keepalive end
    local ok, verified, verify_error = pcall(
        rsaVerifyWith, rsa, tostring(data or ""), tostring(signature or ""), algorithm)
    libcrypto.RSA_free(rsa)
    if not ok then return nil, "RSA ABI mismatch: " .. tostring(verified) end
    return verified, verify_error
end

function CryptoCompat:rsaVerifyComponents(modulus, exponent, data, signature, algorithm)
    return self:rsaVerify(rsaPublicDerFromComponents(modulus, exponent), data, signature, algorithm)
end

function CryptoCompat:toSignedByteArray(value)
    local output = {}
    for index = 1, #tostring(value or "") do
        local byte = tostring(value):byte(index)
        output[index] = byte >= 128 and byte - 256 or byte
    end
    return output
end

function CryptoCompat:isNative()
    return libcrypto ~= nil
end

function CryptoCompat:digestHex(value, algorithm)
    return Digest:digest(value, algorithm)
end

function CryptoCompat:hmacHex(value, algorithm, key)
    return Digest:hmac(value, algorithm, key)
end

function CryptoCompat:hmacBase64(value, algorithm, key)
    return base64Encode(Digest:hmacBinary(value, algorithm, key))
end

function CryptoCompat:randomUUID()
    local seed = tostring(os.time()) .. ":" .. tostring(os.clock()) .. ":" .. tostring({})
    local bytes = unhex(Digest:sha256(seed):sub(1, 32))
    local values = { bytes:byte(1, 16) }
    values[7] = (values[7] % 16) + 0x40
    values[9] = (values[9] % 64) + 0x80
    local h = {}
    for index, value in ipairs(values) do h[index] = string.format("%02x", value) end
    return table.concat(h, "", 1, 4) .. "-" .. table.concat(h, "", 5, 6) .. "-" .. table.concat(h, "", 7, 8)
        .. "-" .. table.concat(h, "", 9, 10) .. "-" .. table.concat(h, "", 11, 16)
end

function CryptoCompat:createSymmetricCrypto(transformation, key, iv)
    local function binary(value)
        if type(value) == "table" and rawget(value, "kind") == "java_byte_array" then
            return rawget(value, "bytes") or ""
        end
        if type(value) == "table" and type(rawget(value, "value")) == "table" then value = rawget(value, "value") end
        if type(value) == "table" then
            local output, index = {}, 1
            local position = (value[0] ~= nil or value["0"] ~= nil) and 0 or 1
            while index <= 8 * 1024 * 1024 do
                local item = value[position] or value[tostring(position)]
                if item == nil then break end
                output[index] = string.char((tonumber(item) or 0) % 256)
                index, position = index + 1, position + 1
            end
            return table.concat(output)
        end
        return tostring(value or "")
    end
    local crypto = {
        transformation = tostring(transformation or "AES/CBC/PKCS5Padding"),
        key = binary(key),
        iv = binary(iv),
    }
    crypto.encrypt = function(self, value)
        local result, err = crypt(true, self.transformation, binary(value), self.key, self.iv)
        if not result then error(err or "encryption failed") end
        return result
    end
    crypto.encryptBase64 = function(self, value) return base64Encode(self:encrypt(value)) end
    crypto.decrypt = function(self, value)
        local input = binary(value)
        local result, err = crypt(false, self.transformation, input, self.key, self.iv)
        if not result then error(err or "decryption failed") end
        return result
    end
    crypto.decryptStr = function(self, value)
        -- Legado exposes decryptStr for both Base64 text and an already
        -- decoded Java byte[].  The latter must stay binary: turning the
        -- opaque byte-array handle into "table: 0x..." and decoding that text
        -- corrupts aggregate responses after the compact byte bridge.
        if type(value) == "table" then return self:decrypt(binary(value)) end
        local input = tostring(value or "")
        local decoded = base64Decode(input)
        -- Legado sources overwhelmingly pass Base64 here; when the input is not
        -- plausible Base64, preserve binary input rather than corrupting it.
        if input == "" or (#decoded == 0 and #input > 0) then decoded = input end
        return self:decrypt(decoded)
    end
    return crypto
end

function CryptoCompat:aesBase64DecodeToString(value, key, transformation, iv)
    return self:createSymmetricCrypto(transformation or "AES/CBC/PKCS5Padding", key, iv):decryptStr(value)
end

function CryptoCompat:desEncodeToBase64String(value, key, transformation, iv)
    return self:createSymmetricCrypto(transformation or "DES/ECB/PKCS5Padding", key, iv):encryptBase64(value)
end

return CryptoCompat
