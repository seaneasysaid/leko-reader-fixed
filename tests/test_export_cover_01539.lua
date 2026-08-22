local plugin_root = assert(arg[1]):gsub("\\", "/")
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

local output = assert(os.getenv("LEKO_SOURCE_LAB_TEST_TMP")):gsub("\\", "/")
local function write(path, value)
    local file = assert(io.open(path, "wb")); assert(file:write(value)); file:close()
end
local function read(path)
    local file = assert(io.open(path, "rb")); local value = file:read("*a"); file:close(); return value
end
local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close(); return true
end
local function be16(value) return string.char(math.floor(value / 256) % 256, value % 256) end
local function be32(value)
    return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256, value % 256)
end
local function le24(value) return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256) end

local jpeg = "\255\216\255\224" .. be16(4) .. "AB"
    .. "\255\192" .. be16(17) .. "\8" .. be16(2) .. be16(2) .. "\3"
    .. "\1\17\0\2\17\0\3\17\0" .. "\255\217"
local png = "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(2) .. be32(2)
    .. "\8\2\0\0\0" .. "xxxx"
local webp = "RIFF" .. string.rep("\0", 4) .. "WEBPVP8X" .. string.rep("\0", 4)
    .. string.rep("\0", 4) .. le24(1) .. le24(1)
local webp_path = output .. "/cover-01539.webp"
write(webp_path, webp)

local ImageInfo = require("Leko/ImageInfo")
local fake_pipeline = {
    saved_policy = { max_bytes = 8 * 1024 * 1024, max_pixels = 12000000,
        max_side = 6000, require_dimensions = true, require_complete_jpeg = true },
    freed = 0,
}
function fake_pipeline:prepare(body, content_type, options)
    local info, inspect_err = ImageInfo:inspect(body)
    if not info then return nil, inspect_err end
    local allowed, policy_err = ImageInfo:checkPolicy(info, #body, options and options.policy)
    if not allowed then return nil, policy_err end
    local result = { body = body, content_type = content_type, ext = info.format, info = info }
    if not options or options.decode ~= false then
        result.image = {
            writeToFile = function(_, path, format)
                assert(format == "png")
                write(path, png)
                return true
            end,
        }
    end
    return result
end
function fake_pipeline:encodeImage(image, path, format)
    return image:writeToFile(path, format) and read(path)
end
function fake_pipeline:freeImage(image)
    if image then self.freed = self.freed + 1 end
end
package.loaded["Leko/ImagePipeline"] = fake_pipeline

local Storage = { load_count = 0, allow_cover = true }
local latest = {
    id = "cover-race-01539", title = "cover-race-01539", author = "test-author",
    cover = "cached-cover-descriptor", cover_path = nil,
    chapters = {
        { id = "c1", title = "第一章" }, { id = "c2", title = "第二章" },
    },
}
local chapter_paths = {}
for index, chapter in ipairs(latest.chapters) do
    chapter_paths[index] = output .. "/cover-01539-chapter-" .. tostring(index) .. ".txt"
    chapter.path = chapter_paths[index]
    write(chapter.path, "正文第" .. tostring(index) .. "章")
end
function Storage:getExportDir() return output end
function Storage:getChapterPath(_, index) return chapter_paths[index] end
function Storage:loadChapter(_, index) return read(chapter_paths[index]) end
function Storage:isInLibrary() return true end
function Storage:loadBook(id)
    self.load_count = self.load_count + 1
    assert(id == latest.id)
    return latest
end
package.loaded["Leko/Storage"] = Storage
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, field)
        if not exists(path) then return nil end
        local value = { mode = "file", size = 1 }
        return field and value[field] or value
    end,
}
package.loaded["Leko/Util"] = {
    dirname = function(path) return tostring(path):match("^(.*)[/\\][^/\\]+$") or "." end,
    joinPath = function(left, right) return tostring(left):gsub("[/\\]+$", "") .. "/" .. tostring(right) end,
    mkdirp = function() return true end,
    readFile = function(path) return exists(path) and read(path) or nil end,
    normalizeText = function(value) return tostring(value or "") end,
    truncateUtf8 = function(value) return tostring(value or "") end,
    hashId = function() return "1234abcd" end,
}

local BookService = { materialize_calls = 0 }
function BookService:getValidCoverPath(book)
    if book.cover_path and exists(book.cover_path) then return book.cover_path end
    return nil, "cover path is absent"
end
function BookService:materializeCachedCover(book)
    self.materialize_calls = self.materialize_calls + 1
    if not Storage.allow_cover then return nil, false, "cover cache is unavailable" end
    book.cover_path = webp_path
    latest.cover_path = webp_path
    return webp_path, true
end
package.preload["Leko/BookService"] = function() return BookService end

local Exporter = require("Leko/BookExporter")
local epub, epub_err, epub_meta = Exporter:export({ id = latest.id, title = latest.title,
    chapters = latest.chapters }, "epub")
assert(epub, epub_err)
local epub_data = read(epub)
assert(epub_data:find("cover.png", 1, true), "EPUB cover was not converted to PNG")
assert(epub_data:find('properties="cover-image"', 1, true), "EPUB cover-image property is missing")
assert(epub_data:find('<meta name="cover" content="cover-image"', 1, true), "EPUB cover metadata is missing")
assert(epub_data:find('<reference type="cover"', 1, true), "EPUB cover guide is missing")
assert(epub_data:find("\137PNG\r\n\26\n", 1, true), "EPUB converted cover bytes are missing")
assert(BookService.materialize_calls == 1 and Storage.load_count >= 2,
    "export did not reload and persist the latest cover state")

local mobi = assert(Exporter:export({ id = latest.id, title = latest.title,
    chapters = latest.chapters }, "mobi"))
local mobi_data = read(mobi)
local function u32(position)
    local a, b, c, d = mobi_data:byte(position, position + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end
local record0 = u32(79)
local first_image = u32(record0 + 109)
assert(first_image ~= 0xffffffff, "MOBI first image index is missing")
local image_record = u32(79 + first_image * 8)
assert(mobi_data:sub(image_record + 1, image_record + 8) == "\137PNG\r\n\26\n",
    "MOBI image record is not the converted PNG")
local exth = assert(mobi_data:find("EXTH", record0 + 1, true), "MOBI EXTH header is missing")
local exth_count = u32(exth + 8)
local cursor = exth + 12
local saw_cover_offset = false
for _ = 1, exth_count do
    local kind, length = u32(cursor), u32(cursor + 4)
    if kind == 201 then saw_cover_offset = u32(cursor + 8) == 0 end
    cursor = cursor + length
end
assert(saw_cover_offset, "MOBI EXTH 201 cover offset is missing")
assert(mobi_data:find('<reference type="cover"', 1, true)
    and mobi_data:find('recindex="00001"', 1, true), "MOBI cover guide is missing")

latest.cover_path = nil
latest.cover = nil
Storage.allow_cover = false
local no_cover, no_cover_err, no_cover_meta = Exporter:export({ id = latest.id, title = latest.title,
    chapters = latest.chapters }, "epub")
assert(no_cover, no_cover_err)
assert(no_cover_meta and tostring(no_cover_meta.cover_warning):find("封面", 1, true),
    "missing/deleted cover did not produce an explicit warning")
assert(fake_pipeline.freed >= 2, "converted cover BlitBuffers were not freed")

print("cover persistence race, EPUB/MOBI conversion metadata, and missing-cover warning: OK")
