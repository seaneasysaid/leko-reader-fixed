-- Small deterministic digest helpers used by book-source rules.  This module
-- intentionally implements only portable algorithms that do not depend on the
-- Android/Java bridge.
local Digest = {}

local ok_bit, bit = pcall(require, "bit")
if not ok_bit then bit = require("bit32") end
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift
local rol = bit.rol or bit.lrotate
local ror = bit.ror or bit.rrotate
if not rol then
    rol = function(value, shift)
        shift = shift % 32
        return bor(lshift(value, shift), rshift(value, 32 - shift))
    end
end
if not ror then
    ror = function(value, shift)
        shift = shift % 32
        return bor(rshift(value, shift), lshift(value, 32 - shift))
    end
end

local function u32(value)
    return band(value, 0xffffffff)
end

local function littleWord(text, offset)
    local a, b, c, d = text:byte(offset, offset + 3)
    return u32((a or 0) + lshift(b or 0, 8) + lshift(c or 0, 16) + lshift(d or 0, 24))
end

local shifts = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5,9,14,20, 5,9,14,20, 5,9,14,20, 5,9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
}
local constants = {}
for index = 1, 64 do
    constants[index] = math.floor(math.abs(math.sin(index)) * 4294967296) % 4294967296
end

local function wordBytes(value)
    value = u32(value)
    return string.char(
        band(value, 0xff),
        band(rshift(value, 8), 0xff),
        band(rshift(value, 16), 0xff),
        band(rshift(value, 24), 0xff)
    )
end

function Digest:md5Binary(value)
    local message = tostring(value or "")
    local bit_length = #message * 8
    message = message .. string.char(0x80)
    message = message .. string.rep("\0", (56 - (#message % 64)) % 64)
    local low = bit_length % 4294967296
    local high = math.floor(bit_length / 4294967296)
    message = message .. wordBytes(low) .. wordBytes(high)

    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    for block = 1, #message, 64 do
        local words = {}
        for index = 0, 15 do words[index] = littleWord(message, block + index * 4) end
        local a, b, c, d = a0, b0, c0, d0
        for index = 0, 63 do
            local f, g
            if index < 16 then
                f, g = bor(band(b, c), band(bnot(b), d)), index
            elseif index < 32 then
                f, g = bor(band(d, b), band(bnot(d), c)), (5 * index + 1) % 16
            elseif index < 48 then
                f, g = bxor(b, c, d), (3 * index + 5) % 16
            else
                f, g = bxor(c, bor(b, bnot(d))), (7 * index) % 16
            end
            local next_d = d
            d, c, b = c, b, u32(b + rol(u32(a + f + constants[index + 1] + words[g]), shifts[index + 1]))
            a = next_d
        end
        a0, b0, c0, d0 = u32(a0 + a), u32(b0 + b), u32(c0 + c), u32(d0 + d)
    end
    return wordBytes(a0) .. wordBytes(b0) .. wordBytes(c0) .. wordBytes(d0)
end

function Digest:hex(value)
    return (tostring(value or ""):gsub(".", function(char) return string.format("%02x", char:byte()) end))
end

function Digest:md5(value)
    return self:hex(self:md5Binary(value))
end

local function bigWord(value)
    value = u32(value)
    return string.char(
        band(rshift(value, 24), 0xff), band(rshift(value, 16), 0xff),
        band(rshift(value, 8), 0xff), band(value, 0xff)
    )
end

function Digest:sha1Binary(value)
    local message = tostring(value or "")
    local bit_length = #message * 8
    message = message .. string.char(0x80)
    message = message .. string.rep("\0", (56 - (#message % 64)) % 64)
    local high, low = math.floor(bit_length / 4294967296), bit_length % 4294967296
    message = message .. bigWord(high) .. bigWord(low)
    local h0, h1, h2, h3, h4 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
    for block = 1, #message, 64 do
        local w = {}
        for index = 0, 15 do
            local offset = block + index * 4
            local a,b,c,d = message:byte(offset, offset + 3)
            w[index] = u32(lshift(a or 0,24)+lshift(b or 0,16)+lshift(c or 0,8)+(d or 0))
        end
        for index = 16, 79 do w[index] = rol(bxor(w[index-3],w[index-8],w[index-14],w[index-16]),1) end
        local a,b,c,d,e = h0,h1,h2,h3,h4
        for index = 0,79 do
            local f,k
            if index < 20 then f,k=bor(band(b,c),band(bnot(b),d)),0x5a827999
            elseif index < 40 then f,k=bxor(b,c,d),0x6ed9eba1
            elseif index < 60 then f,k=bor(band(b,c),band(b,d),band(c,d)),0x8f1bbcdc
            else f,k=bxor(b,c,d),0xca62c1d6 end
            local temp=u32(rol(a,5)+f+e+k+w[index])
            e,d,c,b,a=d,c,rol(b,30),a,temp
        end
        h0,h1,h2,h3,h4=u32(h0+a),u32(h1+b),u32(h2+c),u32(h3+d),u32(h4+e)
    end
    return bigWord(h0)..bigWord(h1)..bigWord(h2)..bigWord(h3)..bigWord(h4)
end

function Digest:sha1(value) return self:hex(self:sha1Binary(value)) end

local sha256_k = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

-- ── libcrypto 加速的 SHA-256（2026-11-20）───────────────────────────────
-- 纯 Lua 版单次 sha256 ≈ 80µs（Sean 双机基准：20 万次 Kindle 8.3s / Kobo 16.5s）。
-- 书山段评的 altcha PoW 迭代数方差很大（期望 ~65k 次，尾部可到 40 万），Kobo 上
-- 整个求解 20~40s，直接撞死段评的 60s 子进程超时。KOReader 自带 libcrypto
-- （LibreSSL/OpenSSL），ffi 直调单次 ≈1µs，把 PoW 压回 1 秒级。
-- 加载时用 SHA256("abc") 的标准摘要自检；任何一步不成就整体禁用，
-- sha256Binary 无缝退回下面的纯 Lua 实现 —— 行为完全一致，只差速度。
local _crypto_SHA256, _sha256_md, _sha256_string
do
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and type(ffi) == "table" then
        local ok_cdef = pcall(ffi.cdef,
            -- 用 const char * 声明：LuaJIT 只对 char 指针做 Lua string 自动转换；
            -- 与 lib 里真正的 unsigned char * 形参在 ABI 上完全等价。
            "unsigned char *SHA256(const char *d, size_t n, unsigned char *md);")
        if ok_cdef then
            for _, name in ipairs({ "libcrypto.so.57", "libcrypto.so.1.1", "libcrypto.so.3", "libcrypto" }) do
                local ok_load, lib = pcall(ffi.load, name)
                -- ⚠️ 不能用 type(lib) == "cdata" 判断：KOReader 的 luajit 上
                -- ffi.load 返回值 type() 实测是 "userdata"（2026-11-20 Kobo 实测，
                -- 守卫写 cdata 导致快路径在所有设备上静默失效）。直接试符号。
                if ok_load and lib ~= nil and pcall(function() return lib.SHA256 end) then
                    _crypto_SHA256 = lib.SHA256
                    break
                end
            end
        end
    end
    if _crypto_SHA256 then
        local known = "\xba\x78\x16\xbf\x8f\x01\xcf\xea\x41\x41\x40\xde\x5d\xae\x22\x23"
            .. "\xb0\x03\x61\xa3\x96\x17\x7a\x9c\xb4\x10\xff\x61\xf2\x00\x15\xad" -- SHA256("abc")
        local ok_test, md = pcall(ffi.new, "unsigned char[32]")
        -- md 同样不查 type（同上，可能是 userdata）；能 new 出来就能用。
        if ok_test and md ~= nil then
            local ok_call = pcall(_crypto_SHA256, "abc", 3, md)
            if not ok_call or ffi.string(md, 32) ~= known then
                _crypto_SHA256 = nil
            else
                _sha256_md = md
                _sha256_string = ffi.string
            end
        else
            _crypto_SHA256 = nil
        end
    end
end

local function sha256BinaryFast(value)
    _crypto_SHA256(value, #value, _sha256_md)
    return _sha256_string(_sha256_md, 32)
end

function Digest:sha256Binary(value)
    if _crypto_SHA256 then return sha256BinaryFast(value) end
    local message = tostring(value or "")
    local bit_length = #message * 8
    message = message .. string.char(0x80)
    message = message .. string.rep("\0", (56 - (#message % 64)) % 64)
    local high, low = math.floor(bit_length / 4294967296), bit_length % 4294967296
    message = message .. bigWord(high) .. bigWord(low)
    local h = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
    for block = 1, #message, 64 do
        local w = {}
        for index = 0, 15 do
            local offset = block + index * 4
            local a,b,c,d = message:byte(offset, offset + 3)
            w[index] = u32(lshift(a or 0,24)+lshift(b or 0,16)+lshift(c or 0,8)+(d or 0))
        end
        for index = 16, 63 do
            local s0 = bxor(ror(w[index-15],7), ror(w[index-15],18), rshift(w[index-15],3))
            local s1 = bxor(ror(w[index-2],17), ror(w[index-2],19), rshift(w[index-2],10))
            w[index] = u32(w[index-16] + s0 + w[index-7] + s1)
        end
        local a,b,c,d,e,f,g,hh = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
        for index = 0, 63 do
            local S1 = bxor(ror(e,6), ror(e,11), ror(e,25))
            local ch = bxor(band(e,f), band(bnot(e),g))
            local temp1 = u32(hh + S1 + ch + sha256_k[index+1] + w[index])
            local S0 = bxor(ror(a,2), ror(a,13), ror(a,22))
            local maj = bxor(band(a,b), band(a,c), band(b,c))
            local temp2 = u32(S0 + maj)
            hh,g,f,e,d,c,b,a = g,f,e,u32(d+temp1),c,b,a,u32(temp1+temp2)
        end
        h[1],h[2],h[3],h[4] = u32(h[1]+a),u32(h[2]+b),u32(h[3]+c),u32(h[4]+d)
        h[5],h[6],h[7],h[8] = u32(h[5]+e),u32(h[6]+f),u32(h[7]+g),u32(h[8]+hh)
    end
    local out = {}
    for index = 1, 8 do out[index] = bigWord(h[index]) end
    return table.concat(out)
end

function Digest:sha256(value) return self:hex(self:sha256Binary(value)) end

function Digest:digestBinary(value, algorithm)
    algorithm = tostring(algorithm or "MD5"):lower():gsub("[^a-z0-9]", "")
    if algorithm == "sha256" then return self:sha256Binary(value) end
    if algorithm == "sha1" then return self:sha1Binary(value) end
    return self:md5Binary(value)
end

function Digest:digest(value, algorithm)
    return self:hex(self:digestBinary(value, algorithm))
end

function Digest:hmacBinary(value, algorithm, key)
    algorithm = tostring(algorithm or "HmacMD5"):lower():gsub("[^a-z0-9]", "")
    key, value = tostring(key or ""), tostring(value or "")
    local digest
    if algorithm:find("sha256",1,true) then digest = function(v) return self:sha256Binary(v) end
    elseif algorithm:find("sha1",1,true) then digest = function(v) return self:sha1Binary(v) end
    else digest = function(v) return self:md5Binary(v) end end
    local block_size = 64
    if #key > block_size then key = digest(key) end
    key = key .. string.rep("\0", block_size - #key)
    local inner, outer = {}, {}
    for index = 1,block_size do
        local byte=key:byte(index) or 0
        inner[index]=string.char(bxor(byte,0x36)); outer[index]=string.char(bxor(byte,0x5c))
    end
    return digest(table.concat(outer)..digest(table.concat(inner)..value))
end

function Digest:hmac(value, algorithm, key)
    return self:hex(self:hmacBinary(value, algorithm, key))
end

return Digest
