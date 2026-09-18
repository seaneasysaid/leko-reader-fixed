-- Dependency-free symmetric crypto fallback for KOReader builds whose bundled
-- libcrypto lacks a requested legacy cipher. CryptoCompat keeps native EVP as
-- the fast path; this module provides portable AES, DES and 3DES/DESede with
-- the narrow ECB/CBC and padding semantics used by imported Legado sources.

local bit = require("bit")

local PureCrypto = {}

local bxor, band = bit.bxor, bit.band

local SBOX = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
}

local INV_SBOX = {
    0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
    0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
    0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
    0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
    0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
    0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
    0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
    0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
    0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
    0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
    0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
    0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
    0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
    0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
    0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
    0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d,
}

local RCON = { 0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36 }

local function bytes(value)
    return { tostring(value or ""):byte(1, -1) }
end

local function expandKey(key)
    local raw = bytes(key)
    local nk = #raw / 4
    if nk ~= 4 and nk ~= 6 and nk ~= 8 then return nil, "AES key must be 16, 24, or 32 bytes" end
    local nr = nk + 6
    local words = {}
    for index = 0, nk - 1 do
        words[index] = { raw[index * 4 + 1], raw[index * 4 + 2], raw[index * 4 + 3], raw[index * 4 + 4] }
    end
    for index = nk, 4 * (nr + 1) - 1 do
        local previous = words[index - 1]
        local temp = { previous[1], previous[2], previous[3], previous[4] }
        if index % nk == 0 then
            temp = { SBOX[temp[2] + 1], SBOX[temp[3] + 1], SBOX[temp[4] + 1], SBOX[temp[1] + 1] }
            temp[1] = bxor(temp[1], RCON[index / nk])
        elseif nk > 6 and index % nk == 4 then
            for j = 1, 4 do temp[j] = SBOX[temp[j] + 1] end
        end
        local prior = words[index - nk]
        words[index] = {
            bxor(prior[1], temp[1]), bxor(prior[2], temp[2]),
            bxor(prior[3], temp[3]), bxor(prior[4], temp[4]),
        }
    end
    return words, nr
end

local function addRoundKey(state, words, round)
    for column = 0, 3 do
        local word = words[round * 4 + column]
        local offset = column * 4
        for row = 1, 4 do state[offset + row] = bxor(state[offset + row], word[row]) end
    end
end

local function substitute(state, box)
    for index = 1, 16 do state[index] = box[state[index] + 1] end
end

local function shiftRows(state, inverse)
    local original = { unpack(state) }
    for row = 0, 3 do
        for column = 0, 3 do
            local source_column = inverse and ((column - row) % 4) or ((column + row) % 4)
            state[column * 4 + row + 1] = original[source_column * 4 + row + 1]
        end
    end
end

local function multiply(a, b)
    local result = 0
    while b > 0 do
        if b % 2 == 1 then result = bxor(result, a) end
        local high = band(a, 0x80) ~= 0
        a = band(a * 2, 0xff)
        if high then a = bxor(a, 0x1b) end
        b = math.floor(b / 2)
    end
    return band(result, 0xff)
end

local function mixColumns(state, inverse)
    for column = 0, 3 do
        local offset = column * 4
        local a, b, c, d = state[offset + 1], state[offset + 2], state[offset + 3], state[offset + 4]
        if inverse then
            state[offset + 1] = bxor(multiply(a,14), multiply(b,11), multiply(c,13), multiply(d,9))
            state[offset + 2] = bxor(multiply(a,9), multiply(b,14), multiply(c,11), multiply(d,13))
            state[offset + 3] = bxor(multiply(a,13), multiply(b,9), multiply(c,14), multiply(d,11))
            state[offset + 4] = bxor(multiply(a,11), multiply(b,13), multiply(c,9), multiply(d,14))
        else
            state[offset + 1] = bxor(multiply(a,2), multiply(b,3), c, d)
            state[offset + 2] = bxor(a, multiply(b,2), multiply(c,3), d)
            state[offset + 3] = bxor(a, b, multiply(c,2), multiply(d,3))
            state[offset + 4] = bxor(multiply(a,3), b, c, multiply(d,2))
        end
    end
end

local function encryptAESBlock(block, words, rounds)
    local state = bytes(block)
    addRoundKey(state, words, 0)
    for round = 1, rounds - 1 do
        substitute(state, SBOX); shiftRows(state, false); mixColumns(state, false); addRoundKey(state, words, round)
    end
    substitute(state, SBOX); shiftRows(state, false); addRoundKey(state, words, rounds)
    return string.char(unpack(state))
end

local function decryptAESBlock(block, words, rounds)
    local state = bytes(block)
    addRoundKey(state, words, rounds)
    for round = rounds - 1, 1, -1 do
        shiftRows(state, true); substitute(state, INV_SBOX); addRoundKey(state, words, round); mixColumns(state, true)
    end
    shiftRows(state, true); substitute(state, INV_SBOX); addRoundKey(state, words, 0)
    return string.char(unpack(state))
end

local function xorBlock(left, right, size)
    local output = {}
    for index = 1, size do output[index] = string.char(bxor(left:byte(index), right:byte(index))) end
    return table.concat(output)
end

local function normalizeMode(mode, iv, block_size, algorithm)
    mode = tostring(mode or "CBC"):upper()
    if mode ~= "CBC" and mode ~= "ECB" then
        return nil, "pure " .. algorithm .. " fallback supports CBC and ECB only"
    end
    iv = tostring(iv or "")
    if mode == "CBC" and #iv ~= block_size then
        return nil, algorithm .. "/CBC IV must be " .. block_size .. " bytes"
    end
    return mode, iv
end

local function normalizePadding(padding)
    if padding == true or padding == nil then return "PKCS5PADDING" end
    if padding == false then return "NOPADDING" end
    local value = tostring(padding):upper():gsub("[%s_%-]", "")
    if value == "PKCS7PADDING" then value = "PKCS5PADDING" end
    if value ~= "PKCS5PADDING" and value ~= "NOPADDING" and value ~= "ZEROPADDING" then
        return nil, "unsupported padding " .. tostring(padding)
    end
    return value
end

local function pad(input, block_size, padding)
    padding = normalizePadding(padding)
    if not padding then return nil, "unsupported padding" end
    if padding == "PKCS5PADDING" then
        local amount = block_size - (#input % block_size)
        return input .. string.rep(string.char(amount), amount)
    elseif padding == "ZEROPADDING" then
        local remainder = #input % block_size
        return remainder == 0 and input or (input .. string.rep("\0", block_size - remainder))
    elseif #input % block_size ~= 0 then
        return nil, "input is not block-aligned"
    end
    return input
end

local function unpad(input, block_size, padding)
    padding = normalizePadding(padding)
    if not padding then return nil, "unsupported padding" end
    if padding == "ZEROPADDING" then return input:match("^(.-)%z*$") or input end
    if padding == "NOPADDING" then return input end
    local amount = input:byte(-1) or 0
    if amount < 1 or amount > block_size or #input < amount then return nil, "invalid PKCS padding" end
    for index = #input - amount + 1, #input do
        if input:byte(index) ~= amount then return nil, "invalid PKCS padding" end
    end
    return input:sub(1, #input - amount)
end

local function encryptAES(input, key, iv, mode, padding)
    local words, rounds = expandKey(key)
    if not words then return nil, rounds end
    mode, iv = normalizeMode(mode, iv, 16, "AES")
    if not mode then return nil, iv end
    input = tostring(input or "")
    local padded, padding_error = pad(input, 16, padding)
    if not padded then return nil, "AES " .. tostring(padding_error) end
    input = padded
    local output, previous = {}, iv
    for offset = 1, #input, 16 do
        local block = input:sub(offset, offset + 15)
        if mode == "CBC" then block = xorBlock(block, previous, 16) end
        block = encryptAESBlock(block, words, rounds)
        output[#output + 1] = block
        if mode == "CBC" then previous = block end
    end
    return table.concat(output)
end

local function decryptAES(input, key, iv, mode, padding)
    local words, rounds = expandKey(key)
    if not words then return nil, rounds end
    mode, iv = normalizeMode(mode, iv, 16, "AES")
    if not mode then return nil, iv end
    input = tostring(input or "")
    if #input % 16 ~= 0 then return nil, "AES ciphertext is not block-aligned" end
    local output, previous = {}, iv
    for offset = 1, #input, 16 do
        local cipher = input:sub(offset, offset + 15)
        local block = decryptAESBlock(cipher, words, rounds)
        if mode == "CBC" then block = xorBlock(block, previous, 16); previous = cipher end
        output[#output + 1] = block
    end
    local result, padding_error = unpad(table.concat(output), 16, padding)
    if not result then return nil, "AES " .. tostring(padding_error) end
    return result
end

-- DES tables use the bit numbering from FIPS 46-3 (one-based, MSB first).
local DES_IP = {
    58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,
    62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,
    57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,
    61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7,
}
local DES_FP = {
    40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,
    38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,
    36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,
    34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25,
}
local DES_E = {
    32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,
    12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,
    24,25,24,25,26,27,28,29,28,29,30,31,32,1,
}
local DES_P = {
    16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,
    2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25,
}
local DES_PC1 = {
    57,49,41,33,25,17,9,1,58,50,42,34,26,18,
    10,2,59,51,43,35,27,19,11,3,60,52,44,36,
    63,55,47,39,31,23,15,7,62,54,46,38,30,22,
    14,6,61,53,45,37,29,21,13,5,28,20,12,4,
}
local DES_PC2 = {
    14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,
    16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,
    33,48,44,49,39,56,34,53,46,42,50,36,29,32,
}
local DES_SHIFTS = { 1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1 }
local DES_SBOX = {
    {14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7, 0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8, 4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0, 15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13},
    {15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10, 3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5, 0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15, 13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9},
    {10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8, 13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1, 13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7, 1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12},
    {7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15, 13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9, 10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4, 3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14},
    {2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9, 14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6, 4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14, 11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3},
    {12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11, 10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8, 9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6, 4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13},
    {4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1, 13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6, 1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2, 6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12},
    {13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7, 1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2, 7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8, 2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11},
}

local function bitsFromString(value)
    local output = {}
    for index = 1, #value do
        local byte = value:byte(index)
        for shift = 7, 0, -1 do output[#output + 1] = band(math.floor(byte / 2 ^ shift), 1) end
    end
    return output
end

local function stringFromBits(value)
    local output = {}
    for offset = 1, #value, 8 do
        local byte = 0
        for index = 0, 7 do byte = byte * 2 + (value[offset + index] or 0) end
        output[#output + 1] = string.char(byte)
    end
    return table.concat(output)
end

local function permute(value, positions)
    local output = {}
    for index, position in ipairs(positions) do output[index] = value[position] end
    return output
end

local function rotateLeft(value, amount)
    local output, length = {}, #value
    for index = 1, length do output[index] = value[((index + amount - 1) % length) + 1] end
    return output
end

local function desRoundKeys(key)
    if #key ~= 8 then return nil, "DES key must be 8 bytes" end
    local selected = permute(bitsFromString(key), DES_PC1)
    local left, right = {}, {}
    for index = 1, 28 do left[index], right[index] = selected[index], selected[index + 28] end
    local keys = {}
    for round = 1, 16 do
        left, right = rotateLeft(left, DES_SHIFTS[round]), rotateLeft(right, DES_SHIFTS[round])
        local joined = {}
        for index = 1, 28 do joined[index], joined[index + 28] = left[index], right[index] end
        keys[round] = permute(joined, DES_PC2)
    end
    return keys
end

local function desFeistel(right, key)
    local expanded = permute(right, DES_E)
    for index = 1, 48 do expanded[index] = bxor(expanded[index], key[index]) end
    local selected = {}
    for box = 1, 8 do
        local offset = (box - 1) * 6
        local row = expanded[offset + 1] * 2 + expanded[offset + 6]
        local column = expanded[offset + 2] * 8 + expanded[offset + 3] * 4
            + expanded[offset + 4] * 2 + expanded[offset + 5]
        local value = DES_SBOX[box][row * 16 + column + 1]
        for shift = 3, 0, -1 do selected[#selected + 1] = band(math.floor(value / 2 ^ shift), 1) end
    end
    return permute(selected, DES_P)
end

local function cryptDESBlock(block, key, decrypting)
    local keys, err = desRoundKeys(key)
    if not keys then return nil, err end
    local initial = permute(bitsFromString(block), DES_IP)
    local left, right = {}, {}
    for index = 1, 32 do left[index], right[index] = initial[index], initial[index + 32] end
    for round = 1, 16 do
        local f = desFeistel(right, keys[decrypting and (17 - round) or round])
        local next_right = {}
        for index = 1, 32 do next_right[index] = bxor(left[index], f[index]) end
        left, right = right, next_right
    end
    local combined = {}
    for index = 1, 32 do combined[index], combined[index + 32] = right[index], left[index] end
    return stringFromBits(permute(combined, DES_FP))
end

local function splitDESKeys(algorithm, key)
    if algorithm == "DES" then
        if #key ~= 8 then return nil, "DES key must be 8 bytes" end
        return { key }
    end
    if #key ~= 16 and #key ~= 24 then return nil, "3DES key must be 16 or 24 bytes" end
    return { key:sub(1, 8), key:sub(9, 16), #key == 16 and key:sub(1, 8) or key:sub(17, 24) }
end

local function cryptDESFamilyBlock(block, keys, decrypting)
    if #keys == 1 then return cryptDESBlock(block, keys[1], decrypting) end
    if decrypting then
        block = assert(cryptDESBlock(block, keys[3], true))
        block = assert(cryptDESBlock(block, keys[2], false))
        return cryptDESBlock(block, keys[1], true)
    end
    block = assert(cryptDESBlock(block, keys[1], false))
    block = assert(cryptDESBlock(block, keys[2], true))
    return cryptDESBlock(block, keys[3], false)
end

local function cryptDESFamily(encrypting, algorithm, input, key, iv, mode, padding)
    local keys, key_error = splitDESKeys(algorithm, key)
    if not keys then return nil, key_error end
    mode, iv = normalizeMode(mode, iv, 8, algorithm)
    if not mode then return nil, iv end
    input = tostring(input or "")
    if encrypting then
        local padded, padding_error = pad(input, 8, padding)
        if not padded then return nil, algorithm .. " " .. tostring(padding_error) end
        input = padded
    elseif #input % 8 ~= 0 then
        return nil, algorithm .. " ciphertext is not block-aligned"
    end
    local output, previous = {}, iv
    for offset = 1, #input, 8 do
        local source = input:sub(offset, offset + 7)
        local block = source
        if encrypting and mode == "CBC" then block = xorBlock(block, previous, 8) end
        block = cryptDESFamilyBlock(block, keys, not encrypting)
        if not encrypting and mode == "CBC" then block = xorBlock(block, previous, 8) end
        output[#output + 1] = block
        if mode == "CBC" then previous = encrypting and block or source end
    end
    local result = table.concat(output)
    if encrypting then return result end
    local unpadded, padding_error = unpad(result, 8, padding)
    if not unpadded then return nil, algorithm .. " " .. tostring(padding_error) end
    return unpadded
end

function PureCrypto:encrypt(algorithm, input, key, iv, mode, padding)
    algorithm = tostring(algorithm or "AES"):upper()
    if algorithm == "AES" then return encryptAES(input, key, iv, mode, padding) end
    if algorithm == "DESEDE" or algorithm == "3DES" or algorithm == "TRIPLEDES" then algorithm = "3DES" end
    if algorithm == "DES" or algorithm == "3DES" then
        return cryptDESFamily(true, algorithm, input, tostring(key or ""), iv, mode, padding)
    end
    return nil, "unsupported pure cipher " .. algorithm
end

function PureCrypto:decrypt(algorithm, input, key, iv, mode, padding)
    algorithm = tostring(algorithm or "AES"):upper()
    if algorithm == "AES" then return decryptAES(input, key, iv, mode, padding) end
    if algorithm == "DESEDE" or algorithm == "3DES" or algorithm == "TRIPLEDES" then algorithm = "3DES" end
    if algorithm == "DES" or algorithm == "3DES" then
        return cryptDESFamily(false, algorithm, input, tostring(key or ""), iv, mode, padding)
    end
    return nil, "unsupported pure cipher " .. algorithm
end

return PureCrypto
