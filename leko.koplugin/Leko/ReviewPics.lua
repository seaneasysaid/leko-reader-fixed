--[[--
段评图片缓存：目录、命名、路径与内容校验（Leko 版，移植自 fanqie.review_pics）。

目录结构：<KOReader 数据目录>/leko/cache/review_pics/<book_id>/<稳定哈希>.<ext>

按 book_id 分子目录：清理「全部缓存」时整目录删除，不会误删封面缓存。

与 images/（封面）完全独立：混目录会让两边的清理互相误删。
]]--

local lfs = require("libs/libkoreader-lfs")
local Storage = require("Leko/Storage")

local ok_md5, md5 = pcall(require, "md5")

local M = {}

M.DIR_NAME = "review_pics"

local function is_dir(path)
    if type(path) ~= "string" then return false end
    local ok, mode = pcall(lfs.attributes, path, "mode")
    return ok and mode == "directory"
end

local function ensure_path(target)
    if type(target) ~= "string" or target == "" then return end
    if is_dir(target) then return end
    local acc = target:match("^%a:[/\\]") or target:match("^/") or ""
    local rest = target:sub(#acc + 1)
    for seg in rest:gmatch("[^/\\]+") do
        acc = acc .. seg
        if not is_dir(acc) then pcall(lfs.mkdir, acc) end
        acc = acc .. "/"
    end
end

--- 根目录：<leko cache>/review_pics
function M.base()
    local cache = type(Storage.getCacheDir) == "function" and Storage:getCacheDir() or nil
    if not cache or cache == "" then cache = "/tmp/leko-cache" end
    return cache .. "/" .. M.DIR_NAME
end

local function sanitize(seg)
    return (tostring(seg or ""):gsub("[/\\:%*%?\"<>|]", "_"))
end

--- 单本书的图片目录：<base>/<book_id>
function M.dir(book_id)
    if book_id == nil or tostring(book_id) == "" then return nil end
    return M.base() .. "/" .. sanitize(book_id)
end

function M.ensure(book_id)
    local dir = M.dir(book_id)
    if dir then ensure_path(dir) end
    return dir
end

local function url_key(url)
    if ok_md5 and md5 and md5.sumhexa then
        local ok, hex = pcall(md5.sumhexa, url)
        if ok and type(hex) == "string" then return hex end
    end
    -- md5 不可用时的稳定双哈希兜底（%.0f 避开 LuaJIT 整数字面量问题）。
    local h1, h2 = 5381, 52711
    for i = 1, #url do
        local b = url:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
    end
    return string.format("%.0f-%.0f", h1, h2)
end

local function url_ext(url)
    local ext = tostring(url or ""):match("^[^?]*"):match("%.([%a%d]+)$")
    if not ext then return "jpg" end
    ext = ext:lower()
    if ext == "jpeg" then return "jpg" end
    if ext == "png" or ext == "webp" or ext == "gif" or ext == "jpg" then
        return ext
    end
    return "jpg"
end

function M.filename(url)
    if type(url) ~= "string" or url == "" then return nil end
    return url_key(url) .. "." .. url_ext(url)
end

function M.file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    -- file_exists 只判「文件在且非空」：0 字节残骸是下载中断留下的，
    -- 必须当成不存在，否则缓存层会永远不重下这张图。
    local ok, size = pcall(lfs.attributes, path, "size")
    return ok and type(size) == "number" and size > 0
end

--- 字节流是否是真实图片（JPEG / PNG / GIF / WebP / BMP）。
--- 下载层用它在写盘前拦掉错误页；渲染层用它识别历史坏缓存。
function M.is_image_bytes(body)
    if type(body) ~= "string" or #body < 12 then return false end
    local b1, b2, b3, b4 = body:byte(1, 4)
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then return true end          -- JPEG
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return true end -- PNG
    if body:sub(1, 3) == "GIF" then return true end                            -- GIF
    if body:sub(1, 4) == "RIFF" and body:sub(9, 12) == "WEBP" then return true end -- WebP
    if b1 == 0x42 and b2 == 0x4D then return true end                          -- BMP
    return false
end

--- 只读文件头判断缓存是否像图片；读不到按「不是」处理。
function M.looks_like_image(path)
    if type(path) ~= "string" or path == "" then return false end
    local file = io.open(path, "rb")
    if not file then return false end
    local head = file:read(16) or ""
    file:close()
    return M.is_image_bytes(head)
end

return M
