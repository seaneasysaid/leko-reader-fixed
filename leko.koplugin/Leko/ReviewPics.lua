--[[--
段评图片缓存：目录、命名、路径、统计、清理（Leko 版，移植自 fanqie.review_pics）。

目录结构：<KOReader 数据目录>/leko/cache/review_pics/<book_id>/<稳定哈希>.<ext>

按 book_id 分子目录：书移出书架时整目录删除最干净；判据是**集合成员**
（书架还在的书整目录保留），不是 mtime —— mtime 只在写入时更新，常读的书
同样「很旧」，用它清理正是封面缓存踩过的坑。

与 images/（封面）完全独立：混目录会让两边的孤儿清理互相误删。
]]--

local lfs = require("libs/libkoreader-lfs")
local Storage = require("Leko/Storage")
local logger = require("logger")

local ok_md5, md5 = pcall(require, "md5")

local M = {}

M.DIR_NAME = "review_pics"
M.AUTO_PRUNE_BYTES = 100 * 1024 * 1024   -- 段评图比封面小而多，阈值取 100MB

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

function M.path(book_id, url)
    local name = M.filename(url)
    if not name then return nil end
    local dir = M.dir(book_id)
    if not dir then return nil end
    ensure_path(dir)
    return dir .. "/" .. name
end

function M.find(book_id, url)
    local p = M.path(book_id, url)
    if p and M.file_exists(p) then return p end
    return nil
end

function M.stats(dir)
    local out = { count = 0, bytes = 0 }
    if type(dir) ~= "string" then return out end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then return out end
    for name in iter, dir_obj do
        if type(name) == "string" and not name:match("^%.") then
            local path = dir .. "/" .. name
            local ok_a, size = pcall(lfs.attributes, path, "size")
            if ok_a and type(size) == "number" and size > 0 then
                out.count = out.count + 1
                out.bytes = out.bytes + size
            end
        end
    end
    return out
end

function M.total_stats()
    local out = { count = 0, bytes = 0 }
    local base = M.base()
    local ok, iter, dir_obj = pcall(lfs.dir, base)
    if not ok or type(iter) ~= "function" then return out end
    for name in iter, dir_obj do
        if type(name) == "string" and not name:match("^%.") then
            local st = M.stats(base .. "/" .. name)
            out.count = out.count + st.count
            out.bytes = out.bytes + st.bytes
        end
    end
    return out
end

local function rmdir_tree(path)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok or type(iter) ~= "function" then return 0 end
    local removed = 0
    for name in iter, dir_obj do
        if type(name) == "string" and name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            if is_dir(child) then
                removed = removed + rmdir_tree(child)
            elseif os.remove(child) then
                removed = removed + 1
            end
        end
    end
    pcall(lfs.rmdir, path)
    return removed
end

--- 按书架集合清理：删除不在集合内的 <book_id>/ 整个子目录。
-- @param book_ids table 书架 book_id 数组 / set / book 表数组
-- @return deleted_files, freed_bytes
function M.prune_orphans(book_ids)
    local deleted, freed = 0, 0
    if type(book_ids) ~= "table" then return deleted, freed end
    local keep = {}
    local function id_of(v)
        if type(v) == "table" then return v.book_id or v.bookId or v.id end
        return v
    end
    for k, v in pairs(book_ids) do
        local id
        if type(k) == "number" then id = id_of(v) else id = k end
        if id ~= nil and tostring(id) ~= "" then keep[sanitize(id)] = true end
    end
    if next(keep) == nil then return deleted, freed end   -- 空集合不动手

    local base = M.base()
    local ok, iter, dir_obj = pcall(lfs.dir, base)
    if not ok or type(iter) ~= "function" then return deleted, freed end
    local dead = {}
    for name in iter, dir_obj do
        if type(name) == "string" and not name:match("^%.") and not keep[name] then
            local path = base .. "/" .. name
            if is_dir(path) then
                dead[#dead + 1] = { path = path, bytes = M.stats(path).bytes }
            end
        end
    end
    for i = 1, #dead do
        local n = rmdir_tree(dead[i].path)
        if n > 0 then
            deleted = deleted + n
            freed = freed + dead[i].bytes
        end
    end
    if deleted > 0 then
        logger.info("Leko review pics: pruned", deleted, "files, freed", freed, "bytes")
    end
    return deleted, freed
end

--- 阈值触发的自动清理：超过 AUTO_PRUNE_BYTES 才按书架集合删整目录。
function M.maybe_auto_prune(book_ids)
    if type(book_ids) ~= "table" then return 0, 0 end
    local st = M.total_stats()
    if st.bytes < M.AUTO_PRUNE_BYTES then return 0, 0 end
    logger.info("Leko review pics: total", st.bytes, "bytes /", st.count, "images, pruning")
    return M.prune_orphans(book_ids)
end

return M
