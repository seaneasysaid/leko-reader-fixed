--[[--
图片真实尺寸探测（PNG / JPEG / WebP），纯函数、零依赖（移植自 fanqie）。

段评图片的渲染尺寸不能只信服务端字段 —— 模板图经常没有 width/height，
拿不到真实比例时只能退化成正方形兜底框，竖图/横图周围全是留白。
这里直接读文件头拿真实尺寸（三种格式的宽高都在头部几十字节里）。

probe(path) → w, h（都 > 0）；读不到 / 解析不出 → nil, nil。
结果按 path 进程内记忆；损坏 / 非图片同样记 nil，别让坏图每帧重读。
]]--

local M = {}
local MEMO = {}

local function be(buf, i, n)
    local v = 0
    for k = 0, n - 1 do v = v * 256 + buf:byte(i + k) end
    return v
end

local function le(buf, i, n)
    local v = 0
    for k = n - 1, 0, -1 do v = v * 256 + buf:byte(i + k) end
    return v
end

local function png_size(buf)
    if #buf < 24 then return nil end
    if buf:byte(13) ~= 0x49 or buf:byte(14) ~= 0x48
        or buf:byte(15) ~= 0x44 or buf:byte(16) ~= 0x52 then return nil end
    return be(buf, 17, 4), be(buf, 21, 4)
end

local function webp_size(buf)
    if #buf < 30 then return nil end
    if buf:sub(9, 12) ~= "WEBP" then return nil end
    local fourcc = buf:sub(13, 16)
    if fourcc == "VP8X" then
        return le(buf, 25, 3) + 1, le(buf, 28, 3) + 1
    elseif fourcc == "VP8 " then
        if buf:byte(24) ~= 0x9D or buf:byte(25) ~= 0x01 or buf:byte(26) ~= 0x2A then
            return nil
        end
        return le(buf, 27, 2) % 16384, le(buf, 29, 2) % 16384
    elseif fourcc == "VP8L" then
        if buf:byte(21) ~= 0x2F then return nil end
        local b1, b2, b3, b4 = buf:byte(22, 25)
        local w = b1 + (b2 % 64) * 256 + 1
        local h = math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024 + 1
        return w, h
    end
    return nil
end

local JPEG_SOF = {
    [0xC0] = true, [0xC1] = true, [0xC2] = true, [0xC3] = true,
    [0xC5] = true, [0xC6] = true, [0xC7] = true,
    [0xC9] = true, [0xCA] = true, [0xCB] = true,
    [0xCD] = true, [0xCE] = true, [0xCF] = true,
}

local function jpeg_size(buf)
    local i = 3
    while i + 9 <= #buf do
        if buf:byte(i) ~= 0xFF then return nil end
        local marker = buf:byte(i + 1)
        if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) then
            i = i + 2
        elseif JPEG_SOF[marker] then
            return be(buf, i + 7, 2), be(buf, i + 5, 2)
        elseif marker == 0xDA then
            return nil
        else
            i = i + 2 + be(buf, i + 2, 2)
        end
    end
    return nil
end

function M.probe(path)
    local hit = MEMO[path]
    if hit ~= nil then return hit[1], hit[2] end
    local w, h
    local f = io.open(path, "rb")
    if f then
        local head = f:read(65536) or ""
        f:close()
        if #head >= 24 then
            local is_png = head:byte(1) == 0x89 and head:sub(2, 4) == "PNG"
            local is_webp = head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP"
            if is_png then
                w, h = png_size(head)
            elseif is_webp then
                w, h = webp_size(head)
            elseif head:byte(1) == 0xFF and head:byte(2) == 0xD8 then
                w, h = jpeg_size(head)
            end
        end
        if not (w and h and w > 0 and h > 0) then w, h = nil, nil end
    end
    MEMO[path] = { w, h }
    return w, h
end

--- 清空探测记忆（图片被重下覆盖后调；一般同 URL 同模板尺寸不变，无需调）。
function M.forget(path)
    if path then MEMO[path] = nil else MEMO = {} end
end

-- 单测钩子：直接解析头部字节，绕过 io（fengari 无真实文件系统）。
M._test = {
    png = png_size,
    webp = webp_size,
    jpeg = jpeg_size,
}

return M
