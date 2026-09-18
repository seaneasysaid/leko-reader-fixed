local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local AsyncChapterPrefetch = require("Leko/AsyncChapterPrefetch")
local BookIdentity = require("Leko/BookIdentity")
local BookSnapshot = require("Leko/BookSnapshot")
local ImagePipeline = require("Leko/ImagePipeline")
local LegadoSource = require("Leko/LegadoSource")
local Storage = require("Leko/Storage")
local SourcePreference = require("Leko/SourcePreference")
local Util = require("Leko/Util")

local BookService = {
    _chapter_cache = {},
    _cache_order = {},
    -- Keep only previous/current/next parsed chapters in RAM. Background
    -- prefetch stores text on disk and deliberately does not build paragraph models.
    max_cached_chapters = 3,
    _validated_covers = {},
    _validated_cover_order = {},
    max_validated_covers = 24,
    _runtime_sources = {},
    _prefetch_states = {},
    _prefetch_observers = {},
    _full_cache_states = {},
    _full_cache_observers = {},
    -- Disk prefetch is intentionally asymmetric: readers usually move forward,
    -- but the two previous chapters are kept warm for quick backtracking.
    prefetch_window = 5, -- backward-compatible alias for forward window
    prefetch_forward_window = 5,
    prefetch_backward_window = 2,
    prefetch_start_delay = 0.45,
    prefetch_step_delay = 0.12,
    full_cache_start_delay = 0.35,
    full_cache_step_delay = 0.30,
}

local function boundedIntro(value)
    local limit = tonumber(Util.PRESENTATION_TEXT_LIMIT or 500) or 500
    if type(Util.truncateUtf8) == "function" then return Util.truncateUtf8(value, limit) end
    value = tostring(value or "")
    if #value <= limit then return value end
    return value:sub(1, math.max(0, limit - 3)) .. "…"
end

local function boundedCover(value)
    if type(Util.safeCoverDescriptor) == "function" then return Util.safeCoverDescriptor(value) end
    local limit = tonumber(Util.COVER_DESCRIPTOR_LIMIT or (16 * 1024)) or (16 * 1024)
    if value == nil then return nil end
    value = tostring(value)
    if value == "" or #value > limit then return nil end
    return value
end

local function clearInlineResponseFields(value)
    if type(value) ~= "table" then return end
    for _, key in ipairs({
        "toc_html", "info_html", "_detail_response_url", "_detail_request_base_url",
        "_detail_base_url", "_detail_content_type", "_detail_code", "_detail_status",
        "_toc_html_response_url", "_toc_html_request_base_url", "_toc_html_content_type",
    }) do
        value[key] = nil
    end
end

local function inlineResponsePayload(value, source)
    if type(value) ~= "table" then return nil end
    local body = value.toc_html
    if type(body) ~= "string" or body == "" then return nil end
    local response_url = value._toc_html_response_url or value._detail_response_url
        or value._detail_base_url or value.book_url
    local request_base_url = value._toc_html_request_base_url or value._detail_request_base_url
        or value._detail_base_url or response_url
    if tostring(response_url or "") == "" or tostring(request_base_url or "") == "" then return nil end
    return {
        body = body,
        source_id = source and source.id or value.source_id,
        book_url = value.book_url,
        response_url = response_url,
        request_base_url = request_base_url,
        content_type = value._toc_html_content_type or value._detail_content_type or "text/html",
        code = value._detail_code or 200,
        status = value._detail_status or 200,
    }
end

local function saveInlineResponse(book, source, value)
    local payload = inlineResponsePayload(value, source)
    if not payload or type(Storage.saveInlineBookResponse) ~= "function" then return false end
    local ok = Storage:saveInlineBookResponse(book, payload)
    return ok == true
end

local function hydrateInlineResponse(book)
    if type(book) ~= "table" or type(Storage.loadInlineBookResponse) ~= "function" then return false end
    if type(book.toc_html) == "string" and book.toc_html ~= "" then return true end
    local payload = Storage:loadInlineBookResponse(book)
    if not payload then return false end
    book.toc_html = payload.body
    book._toc_html_response_url = payload.response_url
    book._toc_html_request_base_url = payload.request_base_url
    book._toc_html_content_type = payload.content_type
    book._detail_code = payload.code
    book._detail_status = payload.status
    return true
end

local function clearInlineResponse(book)
    if type(book) == "table" and type(Storage.clearInlineBookResponse) == "function" then
        Storage:clearInlineBookResponse(book.id)
    end
    clearInlineResponseFields(book)
end



local function sourceFromRecord(record, source_id)
    if type(record) == "table" and record.records_path and record.record_offset ~= nil
            and record.record_length ~= nil then
        local source = Storage:readSourceRecord(record.records_path, record.record_offset,
            record.record_length, source_id, true)
        if source then return source end
    end
    local source = Storage:getSource(source_id)
    if source then Storage:hydrateSourceRuntime(source) end
    return source
end

local function applySourceRuntime(source, runtime)
    if type(source) ~= "table" or type(runtime) ~= "table" then return source end
    if type(runtime.cookies) == "table" then source.cookies = runtime.cookies end
    if type(runtime.variables) == "table" then source.variables = runtime.variables end
    if runtime.login_header ~= nil then source.login_header = runtime.login_header end
    if type(runtime.login_info) == "table" then source.login_info = runtime.login_info end
    return source
end

local function sourceForCandidate(result)
    if not result or not result.source_id then return nil end
    return sourceFromRecord(result._source_record, result.source_id)
end

--[[--
按书取源：正文 / 目录 / 封面 / 段评都走这一处。

返回的是带 Cookie / 源变量的 runtime 工作副本；搜索结果可能带来更新的副本
（book.candidate_source_runtime），这里负责把它应用到缓存副本上。
换书 / 离开阅读器时 clearTransientMemory 会把这份缓存丢掉。
]]--
function BookService:sourceFor(book)
    if not book or not book.source_id then return nil end
    local book_key = tostring(book.id)
    local source = self._runtime_sources[book_key]
    if source and tostring(source.id) == tostring(book.source_id) then
        -- A repeated search can produce fresher Cookie/variable/login state for
        -- the same book id. Apply it even when the parsed source is cached.
        return applySourceRuntime(source, book.candidate_source_runtime)
    end
    source = sourceFromRecord(book.source_record, book.source_id)
    if source then
        -- Search happens in a different child process. Any Cookie/source-variable
        -- changes made by ruleSearch travel with the selected candidate until the
        -- first detail request can commit them to the source runtime file.
        applySourceRuntime(source, book.candidate_source_runtime)
        self._runtime_sources[book_key] = source
    end
    return source
end

local function sourceForCover(self, book)
    if not book then return nil end
    local source_id = book.cover_source_id or book.source_id
    if not source_id then return nil end
    local cache_key = "cover:" .. tostring(book.id) .. ":" .. tostring(source_id)
    local source = self._runtime_sources[cache_key]
    if source and tostring(source.id) == tostring(source_id) then return source end
    local record = tostring(source_id) == tostring(book.cover_source_id or "")
        and book.cover_source_record or book.source_record
    source = sourceFromRecord(record, source_id)
    if source then self._runtime_sources[cache_key] = source end
    return source
end

local function chapterPath(book, chapter_index)
    local chapter = book and book.chapters and book.chapters[chapter_index]
    if not chapter then return nil end
    return chapter.path or Storage:getChapterPath(book.id, chapter_index, chapter.id)
end

local function chapterOnDisk(book, chapter_index)
    local path = chapterPath(book, chapter_index)
    return path and lfs.attributes(path, "mode") == "file", path
end

local function cacheKey(book_id, chapter_index)
    return tostring(book_id) .. ":" .. tostring(chapter_index)
end

local function mergeChapterState(old_chapters, new_chapters)
    local old_by_id = {}
    for _, chapter in ipairs(old_chapters or {}) do old_by_id[chapter.id] = chapter end
    for index, chapter in ipairs(new_chapters or {}) do
        chapter.index = index
        local old = old_by_id[chapter.id]
        if old then
            chapter.path = old.path
            chapter.downloaded = old.downloaded
            chapter.updated_at = old.updated_at
        end
    end
    return new_chapters
end

local function chapterId(chapter, index)
    if type(chapter) ~= "table" then return tostring(index or "") end
    local id = chapter.id or chapter.url or chapter.title
    return tostring(id or index or "")
end

local function countNewChapters(old_chapters, new_chapters)
    local old_ids = {}
    for index, chapter in ipairs(old_chapters or {}) do
        old_ids[chapterId(chapter, index)] = true
    end
    local count, latest = 0, nil
    for index, chapter in ipairs(new_chapters or {}) do
        if not old_ids[chapterId(chapter, index)] then
            count = count + 1
            latest = chapter and chapter.title or ("第 " .. tostring(index) .. " 章")
        end
    end
    return count, latest
end

local function boundedCheckError(value)
    local text = tostring(value or "未知错误")
    if type(Util.truncateUtf8) == "function" then
        return Util.truncateUtf8(text, 180)
    end
    return text:sub(1, 180)
end

local function markTocSuccess(book, old_chapters, new_chapters)
    local new_count, latest = countNewChapters(old_chapters, new_chapters)
    local previous_unseen = tonumber(book.toc_update_count or 0) or 0
    book.toc_checked_at = os.time()
    book.toc_check_attempted_at = book.toc_checked_at
    book.toc_check_status = "ok"
    book.toc_check_error = nil
    book.toc_last_new_count = new_count
    if new_count > 0 then
        book.toc_update_count = previous_unseen + new_count
        book.toc_update_latest_title = latest
    else
        book.toc_update_count = previous_unseen
    end
    return new_count, latest
end

local function persistTocFailure(book, err)
    if type(book) ~= "table" or not book.id then return end
    book.toc_check_status = "failed"
    book.toc_check_attempted_at = os.time()
    book.toc_check_error = boundedCheckError(err)
    -- A failed check must never mark a new timestamp or dirty the old TOC.
    pcall(Storage.saveBook, Storage, book, {
        save_toc = false,
        save_progress = false,
        force_summary = Storage:isInLibrary(book.id),
    })
end

local function prepareImagePayload(body, content_type, policy)
    local prepared, err = ImagePipeline:prepare(body, content_type, {
        policy = policy or ImagePipeline.search_policy,
        width = 360,
        height = 520,
        keep_image = false,
    })
    if not prepared then return nil, nil, err end
    return prepared.body, prepared.ext, prepared.note, prepared.info
end

local function decodeDataImage(value)
    return ImagePipeline:decodeDataUri(value)
end

local function validateImageFile(path)
    return ImagePipeline:validateFile(path, ImagePipeline.saved_policy, 360, 520)
end

local function rememberValidatedCover(self, path, signature)
    self._validated_covers[path] = signature
    for index = #self._validated_cover_order, 1, -1 do
        if self._validated_cover_order[index] == path then table.remove(self._validated_cover_order, index) end
    end
    self._validated_cover_order[#self._validated_cover_order + 1] = path
    while #self._validated_cover_order > self.max_validated_covers do
        local expired = table.remove(self._validated_cover_order, 1)
        self._validated_covers[expired] = nil
    end
end

local function rememberWrittenCover(self, path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil, "封面写入后不存在" end
    rememberValidatedCover(self, path, tostring(attr.size or 0) .. ":" .. tostring(attr.modification or 0))
    return path
end

local COVER_FIELDS = {
    "cover_path", "manual_cover", "selected_cover_url", "cover_source_id",
    "cover_source_name", "cover_source_record", "cover_book_url",
    "cover_variables", "cover_updated_at", "updated_at",
}

local function commitCoverState(self, book, new_path, mutate, source_override, options)
    options = options or {}
    local snapshot = BookSnapshot:capture(book, COVER_FIELDS)
    local old_path = snapshot.cover_path
    mutate(book)
    -- Cover mutations must be newer than both the shelf summary and any stale
    -- book object held by a parent view. A strict monotonic value also handles
    -- two user actions occurring within the same wall-clock second.
    local cover_stamp = tonumber(os.time()) or 0
    local previous_stamp = tonumber(snapshot.cover_updated_at) or 0
    if cover_stamp <= previous_stamp then cover_stamp = previous_stamp + 1 end
    book.cover_updated_at = cover_stamp
    local committed, commit_err = xpcall(function()
        local saved, save_err = Storage:saveBook(book, {
            force_summary = options.force_summary == true or Storage:isInLibrary(book.id),
            save_progress = false,
        })
        if saved ~= true then error(tostring(save_err or "封面元数据保存失败")) end
        if source_override and source_override.id then
            local runtime_ok, runtime_err = Storage:saveSourceRuntime(source_override)
            if runtime_ok ~= true then error(tostring(runtime_err or "封面书源状态保存失败")) end
        end
    end, function(err)
        return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err)
    end)
    if not committed then
        BookSnapshot:restore(book, snapshot)
        if new_path and new_path ~= old_path then
            self._validated_covers[new_path] = nil
            pcall(os.remove, new_path)
        end
        pcall(Storage.saveBook, Storage, book, {
            force_summary = Storage:isInLibrary(book.id), save_progress = false,
        })
        return nil, "封面提交失败，已恢复原封面：" .. tostring(commit_err)
    end
    local cover_service_ok, CoverService = pcall(require, "Leko/CoverService")
    if cover_service_ok and CoverService then
        pcall(CoverService.clearMemory, CoverService)
        pcall(CoverService.invalidate, CoverService, {
            source_id = snapshot.cover_source_id or book.source_id,
            book_url = snapshot.cover_book_url or book.book_url,
            cover = snapshot.selected_cover_url or book.cover,
        })
    end
    if old_path and old_path ~= new_path then
        self._validated_covers[old_path] = nil
        pcall(os.remove, old_path)
    end
    return new_path or true
end

function BookService:_putCache(book, chapter_index, model)
    local key = cacheKey(book.id, chapter_index)
    self._chapter_cache[key] = model
    for index = #self._cache_order, 1, -1 do
        if self._cache_order[index] == key then table.remove(self._cache_order, index) end
    end
    table.insert(self._cache_order, key)
    while #self._cache_order > self.max_cached_chapters do
        local expired = table.remove(self._cache_order, 1)
        self._chapter_cache[expired] = nil
    end
end

function BookService:clearBookCache(book_id)
    local prefix = tostring(book_id) .. ":"
    for key in pairs(self._chapter_cache) do
        if key:sub(1, #prefix) == prefix then self._chapter_cache[key] = nil end
    end
    for index = #self._cache_order, 1, -1 do
        if self._cache_order[index]:sub(1, #prefix) == prefix then table.remove(self._cache_order, index) end
    end
end

function BookService:clearTransientMemory()
    self._chapter_cache = {}
    self._cache_order = {}
    self._runtime_sources = {}
    self._validated_covers = {}
    self._validated_cover_order = {}
    pcall(Storage.releaseSourceSettings, Storage)
    pcall(Storage.releaseSourceOverrideSettings, Storage)
    -- 段评的内存计数与章节模型同生共死：模型都丢了，计数留着也没用。
    -- 延迟 require，避免模块加载期的相互依赖。
    pcall(function()
        local ParaComments = require("Leko/ParaComments")
        if type(ParaComments.reset) == "function" then ParaComments.reset() end
    end)
    -- 段评弹窗的排版位图缓存同理：模型都没了，位图留着只是占内存。
    pcall(function()
        local ReviewPopup = require("Leko/ReviewPopup")
        if type(ReviewPopup.cleanup) == "function" then ReviewPopup.cleanup() end
    end)
    collectgarbage("collect")
end

function BookService:validateCoverPath(path)
    if not path then return nil, "没有本地封面" end
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil, "封面文件不存在" end
    local signature = tostring(attr.size or 0) .. ":" .. tostring(attr.modification or 0)
    if self._validated_covers[path] == signature then return path end
    local ok, err = validateImageFile(path)
    if not ok then
        self._validated_covers[path] = nil
        return nil, err
    end
    rememberValidatedCover(self, path, signature)
    return path
end

function BookService:invalidateCoverPath(path)
    if path and path ~= "" then self._validated_covers[path] = nil end
end

function BookService:getValidCoverPath(book_or_summary)
    local path = book_or_summary and book_or_summary.cover_path
    if not path then return nil end
    local valid, err = self:validateCoverPath(path)
    if valid then return valid end
    os.remove(path)
    self._validated_covers[path] = nil
    if book_or_summary then book_or_summary.cover_path = nil end
    local id = book_or_summary and book_or_summary.id
    if id then
        local book = book_or_summary.chapters and book_or_summary or Storage:loadBook(id)
        if book then
            -- A stale row can be one repaint behind an asynchronous cover
            -- commit. Never let that stale row erase a newer cover already
            -- persisted in book.lua.
            if tostring(book.cover_path or "") ~= "" and tostring(book.cover_path) ~= tostring(path) then
                local replacement = self:validateCoverPath(book.cover_path)
                if replacement then
                    book_or_summary.cover_path = replacement
                    return replacement
                end
                return nil, err
            end
            book.cover_path = nil
            book.manual_cover = nil
            Storage:saveBook(book, { force_summary = Storage:isInLibrary(id), save_progress = false })
        end
    end
    return nil, err
end

function BookService:ensureCover(book, force)
    if not book then return nil, "book required" end
    local existing = self:getValidCoverPath(book)
    if existing and not force then return existing end
    local cover_spec = boundedCover(book.selected_cover_url or book.cover or book.content_cover)
    if not cover_spec then return nil, "封面地址为空或过长" end

    local response, err = decodeDataImage(cover_spec)
    if not response then
        local source = sourceForCover(self, book)
        if not source then return nil, "找不到封面所属书源" end
        local cover_book_url = book.cover_book_url or book.book_url or source.base_url
        response, err = LegadoSource:requestBinary(source, cover_spec, {
            book = book,
            base_url = cover_book_url,
            referer = cover_book_url,
            variables = book.cover_variables or book.variables,
        }, {
            max_bytes = ImagePipeline.search_policy.max_bytes,
            retries = 0,
            timeout = 4,
            maxtime = 8,
            headers = force and { ["cache-control"] = "no-cache", pragma = "no-cache" } or nil,
        })
    end
    if not response then return nil, err end

    local image_body, ext, normalize_note = prepareImagePayload(response.body, response.content_type, ImagePipeline.search_policy)
    if not image_body then
        local detail = tostring(ext or normalize_note or "封面响应不是有效图片")
        if response.url and response.url ~= "" then detail = detail .. "\n最终地址：" .. tostring(response.url) end
        return nil, detail
    end
    local filename = tostring(book.id) .. "-network-" .. Util.hashId(image_body) .. "." .. ext
    local path = Util.joinPath(Storage:getCoversDir(), filename)
    local ok, write_err = Util.writeFile(path, image_body, true)
    if not ok then return nil, write_err end
    local valid, validate_err = rememberWrittenCover(self, path)
    if not valid then os.remove(path); return nil, validate_err end
    return commitCoverState(self, book, path, function(target)
        target.cover_path = path
        target.manual_cover = nil
        target.cover_source_id = target.cover_source_id or target.source_id
        target.cover_source_name = target.cover_source_name or target.source_name
        target.cover_book_url = target.cover_book_url or target.book_url
        target.selected_cover_url = target.selected_cover_url or cover_spec
        target.updated_at = os.time()
    end)
end

-- Promote a cover that the detail page already fetched and decoded into the
-- bookshelf's persistent cover representation. This is intentionally a
-- cache-only operation: the detail page has already completed the source
-- request, and the bookshelf update must not introduce a second blocking
-- network request. The source-cover cache is bounded by ImagePipeline's
-- existing search response policy and is revalidated with the saved-cover
-- policy before it is committed.
function BookService:materializeCachedCover(book, result, prepared)
    if not book or not book.id then return nil, false, "book required" end
    if not Storage:isInLibrary(book.id) then return nil, false, "book is not in library" end
    local existing = self:getValidCoverPath(book)
    if existing then return existing, false end

    result = result or {}
    local body = type(prepared) == "table" and prepared.body or nil
    local content_type = type(prepared) == "table" and prepared.content_type or nil
    if type(body) ~= "string" or body == "" then
        local CoverService = require("Leko/CoverService")
        body, content_type = CoverService:getCachedBody(result)
    end
    if type(body) ~= "string" or body == "" then
        return nil, false, "cover cache is unavailable"
    end

    local image_body, ext, normalize_note = prepareImagePayload(body, content_type, ImagePipeline.saved_policy)
    if not image_body then
        return nil, false, normalize_note or ext or "cached cover is invalid"
    end
    local filename = tostring(book.id) .. "-network-" .. Util.hashId(image_body) .. "." .. tostring(ext or "jpg")
    local path = Util.joinPath(Storage:getCoversDir(), filename)
    local ok, write_err = Util.writeFile(path, image_body, true)
    if not ok then return nil, false, write_err end
    local valid, validate_err = rememberWrittenCover(self, path)
    if not valid then os.remove(path); return nil, false, validate_err end

    local cover_spec = boundedCover(result.cover or book.selected_cover_url or book.cover or book.content_cover)
    local committed, commit_err = commitCoverState(self, book, path, function(target)
        target.cover_path = path
        target.manual_cover = nil
        target.selected_cover_url = target.selected_cover_url or cover_spec
        target.cover_source_id = result.source_id or target.cover_source_id or target.source_id
        target.cover_source_name = result.source_name or target.cover_source_name or target.source_name
        target.cover_source_record = result._source_record or target.cover_source_record
        target.cover_book_url = result.book_url or target.cover_book_url or target.book_url
        target.cover_variables = result.variables or target.cover_variables or target.variables
        target.updated_at = os.time()
    end)
    if not committed then return nil, false, commit_err end
    return committed, true
end

function BookService:setCoverFromFile(book, source_path)
    if not book then return nil, "book required" end
    local body, read_err = Util.readFile(source_path, true)
    if not body then return nil, read_err end
    if #body > 8 * 1024 * 1024 then return nil, "封面文件超过 8 MiB" end
    local image_body, ext, image_err = prepareImagePayload(body, nil, ImagePipeline.saved_policy)
    if not image_body then return nil, image_err or "请选择 JPG、PNG、WebP、GIF、SVG 或 TIFF 图片" end
    body = image_body
    local filename = tostring(book.id) .. "-manual-" .. Util.hashId(body) .. "." .. ext
    local path = Util.joinPath(Storage:getCoversDir(), filename)
    local ok, write_err = Util.writeFile(path, body, true)
    if not ok then return nil, write_err end
    local valid, validate_err = rememberWrittenCover(self, path)
    if not valid then os.remove(path); return nil, validate_err end
    return commitCoverState(self, book, path, function(target)
        target.cover_path = path
        target.manual_cover = true
        target.cover_source_id = "local"
        target.cover_source_name = "本地图片"
        target.cover_source_record = nil
        target.cover_book_url = nil
        target.selected_cover_url = nil
        target.cover_variables = nil
        target.updated_at = os.time()
    end)
end

function BookService:clearCover(book)
    if not book then return nil, "book required" end
    return commitCoverState(self, book, nil, function(target)
        target.cover_path = nil
        target.manual_cover = nil
        target.cover_source_id = nil
        target.cover_source_name = nil
        target.cover_source_record = nil
        target.cover_book_url = nil
        target.selected_cover_url = nil
        target.cover_variables = nil
        target.updated_at = os.time()
    end)
end

function BookService:reloadNetworkCover(book)
    if not book then return nil, "book required" end
    return self:ensureCover(book, true)
end



function BookService:createSearchTrial(result)
    if type(result) ~= "table" then return nil, "搜索结果无效" end
    local source_id = tostring(result.source_id or "")
    local book_url = tostring(result.book_url or "")
    if source_id == "" or book_url == "" then return nil, "搜索结果缺少书源或书籍地址" end
    local book_id = "net-" .. Util.hashId(source_id .. "\n" .. book_url)
    local existing = Storage:loadBook(book_id, { load_toc = false })
    local in_library = Storage:isInLibrary(book_id)
    if existing and existing.source_id and tostring(existing.source_id) ~= source_id
            and (tonumber(existing.chapter_count or 0) or 0) > 0 then
        existing.in_library = in_library
        existing.not_shelf = not in_library
        existing.chapters = {}
        return existing
    end
    local now = os.time()
    local book = existing or {}
    book.id = book_id
    book.title = tostring(result.title or book.title or "未命名")
    book.author = tostring(result.author or book.author or "")
    book.intro = boundedIntro(result.intro or book.intro or "")
    book.cover = boundedCover(result.cover) or boundedCover(book.cover)
    book.content_cover = boundedCover(result.cover) or boundedCover(book.content_cover) or book.cover
    book.source_id = source_id
    book.source_name = tostring(result.source_name or book.source_name or "")
    book.source_record = result._source_record or book.source_record
    book.book_url = book_url
    -- A ruleSearch tocUrl belongs to a search candidate, not yet to a resolved
    -- book descriptor. The stable flow visits ruleBookInfo before TOC loading;
    -- treating this candidate field as authoritative made normal search-open and
    -- source switching bypass the page that establishes the proper URL/rule
    -- context. Preserve a previously resolved TOC only for an already prepared
    -- book; otherwise force detail hydration in ensureToc().
    local existing_resolved = existing and (existing.detail_resolved == true
        or (tonumber(existing.chapter_count or 0) or 0) > 0)
    book.toc_url = existing_resolved and existing.toc_url or nil
    book.detail_resolved = existing_resolved == true
    book.variables = result.variables or book.variables or {}
    book._search_base_url = result._search_base_url or book._search_base_url
    book.candidate_source_runtime = result._source_runtime or book.candidate_source_runtime
    book.created_at = book.created_at or now
    book.trial_created_at = book.trial_created_at or now
    book.updated_at = now
    book.last_read_at = tonumber(book.last_read_at or 0) or 0
    book.position = book.position or { chapter = 1, paragraph = 1, char = 1 }
    book.chapter_count = tonumber(book.chapter_count or 0) or 0
    book.chapters = {}
    book.in_library = in_library
    book.not_shelf = not in_library
    -- The tap-to-details path is deliberately memory-only: no source parsing,
    -- network request, directory creation or LuaSettings flush. Persist this
    -- compact record only when the user explicitly requests TOC/reading/source
    -- switching, applies a cover, or adds the book to the shelf.
    book._transient_trial = true
    return book
end

function BookService:persistTrialMetadata(book)
    if type(book) ~= "table" or not book.id then return nil, "book required" end
    if book._transient_trial ~= true then return true end
    book._transient_trial = nil
    local ok, err = pcall(Storage.saveBook, Storage, book, {
        save_toc = false,
        save_progress = false,
        skip_summary = true,
    })
    if not ok then
        book._transient_trial = true
        return nil, tostring(err)
    end
    return true
end

local resolveCandidateInfo

local function rangedProgress(callback, first, span, fallback)
    return function(stage, current, total)
        if type(callback) ~= "function" then return end
        local value = tonumber(first) or 0
        current, total = tonumber(current), tonumber(total)
        if current and total and total > 0 then
            value = value + math.floor((tonumber(span) or 0) * math.max(0, math.min(1, current / total)))
        end
        callback(value, stage or fallback, 100)
    end
end

local function detailIdentityWarning(expected, actual)
    local notes = {}
    if tostring(actual.title or "") ~= "" and not BookIdentity:sameTitle(expected.title, actual.title) then
        notes[#notes + 1] = "书源返回书名《" .. tostring(actual.title) .. "》，与所选《"
            .. tostring(expected.title or "") .. "》不同，可能是别名或其他书籍。"
    end
    if BookIdentity:authorDiffers(expected.author, actual.author) then
        notes[#notes + 1] = "书源的作者标注与所选记录不同。"
    end
    if #notes > 0 then return table.concat(notes, "\n") .. "已继续打开，请核对内容。" end
end

function BookService:ensureToc(book, progress_callback)
    if not book then return nil, "book required" end
    local function report(value, text) if progress_callback then progress_callback(value, text, 100) end end
    if book.toc_pending then return self:refreshToc(book, progress_callback) end
    if type(book.chapters) == "table" and #book.chapters > 0 then
        book.chapter_count = #book.chapters
        book.toc_ready = true
        return book
    end
    local cached = Storage:loadBookToc(book.id)
    if type(cached) == "table" and #cached > 0 then
        book.chapters = cached
        book.chapter_count = #cached
        book.toc_ready = true
        return book
    end
    local source = self:sourceFor(book)
    if not source then return nil, "书源不存在" end
    local info = book
    -- A reopened book keeps only the parsed TOC in book.lua.  Rehydrate the
    -- bounded detail hand-off just for the production TOC call; the raw body
    -- is never copied back into persistent book metadata.
    hydrateInlineResponse(book)
    -- Search candidates and old lightweight shelf records are unresolved even
    -- when they happen to carry a toc_url. Only ruleBookInfo is allowed to
    -- promote a candidate into a resolved book descriptor. This restores the
    -- search -> detail -> TOC invariant and avoids guessing URL bases.
    if book.detail_resolved ~= true or tostring(book.toc_url or "") == "" then
        report(5, "获取书籍详情")
        local loaded, info_err = resolveCandidateInfo(source, book, {
            on_progress = rangedProgress(progress_callback, 5, 15, "获取书籍详情"),
        })
        if not loaded then return nil, info_err end
        book._identity_warning = detailIdentityWarning(book, loaded)
        info = loaded
        for _, key in ipairs({ "title", "author", "intro", "cover", "book_url", "toc_url", "toc_html", "info_html",
            "_detail_base_url", "_detail_response_url", "_detail_request_base_url", "_detail_content_type",
            "_detail_code", "_detail_status", "_toc_html_response_url", "_toc_html_request_base_url",
            "_toc_html_content_type", "variables", "_search_base_url" }) do
            if loaded[key] ~= nil then book[key] = loaded[key] end
        end
        book.intro = boundedIntro(book.intro)
        book.cover = boundedCover(book.cover)
        book.detail_resolved = true
        if tostring(info.toc_html or "") == "" and tostring(book.toc_html or "") ~= "" then
            for _, key in ipairs({ "toc_html", "_toc_html_response_url", "_toc_html_request_base_url",
                "_toc_html_content_type", "_detail_response_url", "_detail_request_base_url",
                "_detail_content_type", "_detail_code", "_detail_status" }) do
                if book[key] ~= nil then info[key] = book[key] end
            end
        end
    end
    report(25, "获取章节目录")
    local toc, toc_err = LegadoSource:getToc(source, info, {
        cache_read = true, cache_write = false, save_runtime = false,
        on_progress = rangedProgress(progress_callback, 25, 50, "获取章节目录"),
    })
    if not toc then return nil, "目录请求失败：" .. tostring(toc_err or "未知错误") end
    if #toc == 0 then return nil, "目录为空" end
    -- Retain the exact accepted detail bytes for the first content call.  The
    -- sidecar is keyed and validated by source/book identity and the HTTP
    -- transport's own 8 MiB limit.
    saveInlineResponse(book, source, info)
    local previous_chapters = book.chapters or {}
    book.toc_node_count, book.toc_list_signature = info.toc_node_count, info.toc_list_signature
    book.chapters = mergeChapterState(previous_chapters, toc)
    markTocSuccess(book, previous_chapters, toc)
    book.chapter_count = #book.chapters
    book.toc_ready = true
    book._toc_dirty = true
    -- toc_html is only a request-reuse input. Never persist a detail page body
    -- into book.lua or the shelf summary after the TOC has been extracted.
    clearInlineResponseFields(book)
    if info ~= book then clearInlineResponseFields(info) end
    book.updated_at = os.time()
    report(80, "保存目录")
    local runtime_ok = Storage:saveSourceRuntime(source)
    if runtime_ok == true then book.candidate_source_runtime = nil end
    Storage:saveBook(book, { save_progress = false, skip_summary = not Storage:isInLibrary(book.id) })
    return book
end

local function applyCandidateRuntime(source, result)
    return applySourceRuntime(source, result and result._source_runtime)
end

local function copyCandidate(result)
    local output = {}
    for key, value in pairs(result or {}) do output[key] = value end
    return output
end

local function candidateTocFallbackAllowed(err)
    local text = tostring(err or "")
    local code = tonumber(text:match("HTTP/%d+%.%d+%s+(%d%d%d)")
        or text:match("HTTP%s+(%d%d%d)"))
    return code == 400 or code == 404 or code == 405
end

resolveCandidateInfo = function(source, result, options)
    options = options or {}
    local info, info_err = LegadoSource:getBookInfo(source, result, {
        cache_read = true, cache_write = false, save_runtime = false,
        on_progress = options.on_progress,
    })
    if info then return info end

    -- Some Legado sources deliberately expose a self-contained tocUrl in
    -- ruleSearch while their detail endpoint accepts only a special POST/login
    -- path. A 400/404/405 from that optional detail request must not make an
    -- otherwise readable source unusable. Only fall back to a validated HTTP
    -- toc descriptor; relative/opaque values are never trusted blindly.
    if candidateTocFallbackAllowed(info_err) and tostring(result and result.toc_url or "") ~= "" then
        local toc_request = LegadoSource:resolveCandidateRequest(source, result.toc_url,
            result._search_base_url or source.base_url)
        if toc_request then
            local fallback = copyCandidate(result)
            fallback.toc_url = toc_request
            fallback.detail_resolved = true
            fallback.detail_fallback = true
            return fallback, nil, "详情接口拒绝请求，已使用搜索结果提供的目录地址"
        end
    end
    return nil, "详情请求失败：" .. tostring(info_err or "未知错误")
end

function BookService:prepareSearchResult(result, progress_callback)
    local function report(value, text) if progress_callback then progress_callback(value, text, 100) end end
    local source = sourceForCandidate(result)
    if not source then return nil, "书源不存在" end
    applyCandidateRuntime(source, result)
    -- A search result is only a candidate. Always run ruleBookInfo before TOC
    -- preparation, following the validated search-detail-TOC path. The removed direct-TOC
    -- fast path confused candidate provenance with resolved book metadata and
    -- was the shared regression behind normal search-open and source switching.
    report(5, "获取书籍详情")
    local info, info_err = resolveCandidateInfo(source, result, {
        on_progress = rangedProgress(progress_callback, 5, 15, "获取书籍详情"),
    })
    if not info then return nil, info_err end
    local identity_warning = detailIdentityWarning(result, info)
    info.detail_resolved = true
    report(25, "获取章节目录")
    local toc, toc_err = LegadoSource:getToc(source, info, {
        cache_read = true, cache_write = false, save_runtime = false,
        on_progress = rangedProgress(progress_callback, 25, 50, "获取章节目录"),
    })
    if not toc then return nil, "目录请求失败：" .. tostring(toc_err or "未知错误") end
    if #toc == 0 then return nil, "目录为空" end
    report(80, "保存试读信息")

    local resolved_book_url = info.book_url or result.book_url
    local book_id = "net-" .. Util.hashId(source.id .. "\n" .. tostring(resolved_book_url))
    local existing = Storage:loadBook(book_id)
    local in_library = Storage:isInLibrary(book_id)
    -- Opening the original search result again must not silently undo a content
    -- source the user explicitly selected from the detail page.
    if existing and existing.source_id and tostring(existing.source_id) ~= tostring(source.id)
            and #(existing.chapters or {}) > 0 then
        existing.in_library = in_library
        existing.not_shelf = not in_library
        report(95, "沿用已选择的内容源")
        return existing
    end
    local position = existing and existing.position or { chapter = 1, paragraph = 1, char = 1 }
    local previous_chapters = existing and existing.chapters or {}
    local resolved_cover = (tostring(info.cover or "") ~= "" and info.cover)
        or (tostring(result.cover or "") ~= "" and result.cover)
        or (existing and (existing.content_cover or existing.cover))
    local book = {
        id = book_id,
        title = info.title or result.title or "未命名",
        author = info.author or result.author or "",
        intro = boundedIntro(info.intro or result.intro or ""),
        cover = boundedCover(resolved_cover),
        content_cover = boundedCover(resolved_cover),
        cover_path = existing and existing.cover_path or nil,
        manual_cover = existing and existing.manual_cover or nil,
        selected_cover_url = existing and existing.selected_cover_url or nil,
        cover_source_id = existing and existing.cover_source_id or nil,
        cover_source_name = existing and existing.cover_source_name or nil,
        cover_source_record = existing and existing.cover_source_record or nil,
        cover_book_url = existing and existing.cover_book_url or nil,
        cover_variables = existing and existing.cover_variables or nil,
        cover_updated_at = existing and existing.cover_updated_at or nil,
        source_id = source.id,
        source_name = source.name,
        source_record = result._source_record,
        book_url = resolved_book_url,
        toc_url = info.toc_url,
        -- A detail response may be reused by getToc while this call is in
        -- progress, but its page body is never part of the persisted book
        -- projection. This keeps malformed detail pages out of the shelf.
        detail_resolved = true,
        variables = info.variables or result.variables or {},
        _search_base_url = result._search_base_url,
        created_at = existing and existing.created_at or os.time(),
        trial_created_at = existing and existing.trial_created_at or os.time(),
        updated_at = os.time(),
        last_read_at = existing and existing.last_read_at or 0,
        position = position,
        chapters = mergeChapterState(previous_chapters, toc),
        toc_node_count = info.toc_node_count, toc_list_signature = info.toc_list_signature,
        _toc_dirty = true,
        content_source_profiles = existing and existing.content_source_profiles or {},
        in_library = in_library,
        not_shelf = not in_library,
    }
    markTocSuccess(book, previous_chapters, toc)
    saveInlineResponse(book, source, info)
    Storage:saveBook(book)
    clearInlineResponseFields(info)
    pcall(Storage.saveSourceRuntime, Storage, source)
    report(95, "试读信息已准备")
    return book, nil, identity_warning
end

-- Backward-compatible name used by older callers.
function BookService:addSearchResult(result)
    local book, err = self:prepareSearchResult(result)
    if not book then return nil, err end
    return Storage:addBookToLibrary(book)
end

function BookService:addToBookshelf(book)
    return Storage:addBookToLibrary(book)
end


local function sameBookIdentity(book, result)
    return BookIdentity:sameTitle(book and book.title, result and result.title)
end

function BookService:isSameBook(book, result)
    return sameBookIdentity(book, result)
end

function BookService:listEligibleSourceDescriptors(limit)
    local descriptors = {}
    local summaries = Storage:listSourceSummaries() or {}
    summaries = SourcePreference:sortSummaries(summaries)
    for _, source in ipairs(summaries) do
        if source.enabled ~= false and source.searchable ~= false and source.has_search_url == true then
            descriptors[#descriptors + 1] = { id = source.id, name = source.name }
            if tonumber(limit) and #descriptors >= tonumber(limit) then break end
        end
    end
    return descriptors
end

function BookService:currentContentCandidate(book)
    if not book or not book.source_id then return nil end
    return {
        title = book.title, author = book.author,
        source_id = book.source_id, source_name = book.source_name,
        book_url = book.book_url, toc_url = book.toc_url,
        cover = book.content_cover or book.cover, variables = book.variables,
        _source_record = book.source_record,
        _source_runtime = book.candidate_source_runtime,
        is_current_content = true,
    }
end

function BookService:currentCoverCandidate(book)
    if not book then return nil end
    local cover = book.selected_cover_url or book.content_cover or book.cover
    if not cover or tostring(cover) == "" then return nil end
    return {
        title = book.title, author = book.author,
        source_id = book.cover_source_id or book.source_id,
        source_name = book.cover_source_name or book.source_name,
        book_url = book.cover_book_url or book.book_url,
        cover = cover, variables = book.cover_variables or book.variables,
        _source_record = book.cover_source_record or book.source_record,
        _source_runtime = not book.cover_source_id and book.candidate_source_runtime or nil,
        is_current_cover = true,
    }
end

local function eligibleSearchSources(limit)
    local sources = {}
    for _, descriptor in ipairs(BookService:listEligibleSourceDescriptors(limit)) do
        local source = Storage:getSource(descriptor.id)
        if source then
            Storage:hydrateSourceRuntime(source)
            sources[#sources + 1] = source
        end
    end
    return sources
end

function BookService:searchAlternateSources(book, options)
    options = options or {}
    if not book or not book.title or tostring(book.title) == "" then return nil, "书名为空" end
    local sources = eligibleSearchSources(options.limit)
    if #sources == 0 then return nil, "没有已经启用并且可用于搜书的文字书源" end
    local results, seen, errors = {}, {}, {}
    for index, source in ipairs(sources) do
        if options.progress then pcall(options.progress, index - 1, #sources, "搜索书源：" .. tostring(source.name)) end
        local found, err = LegadoSource:search(source, tostring(book.title), 1)
        if found then
            local result
            for _, item in ipairs(found) do
                if sameBookIdentity(book, item) then result = item; break end
            end
            if result then
                result.source_name = source.name
                result.author_mismatch = BookIdentity:authorDiffers(book.author, result.author)
                local key = tostring(result.source_id) .. "\n" .. tostring(result.book_url)
                if not seen[key] then
                    seen[key] = true
                    results[#results + 1] = result
                end
            end
        elseif err then
            errors[#errors + 1] = tostring(source.name) .. ": " .. tostring(err)
        end
        if options.progress then pcall(options.progress, index, #sources, "已完成 " .. tostring(index) .. "/" .. tostring(#sources)) end
    end
    table.sort(results, function(a, b)
        local ac = tostring(a.source_id or "") == tostring(book.source_id or "") and 0 or 1
        local bc = tostring(b.source_id or "") == tostring(book.source_id or "") and 0 or 1
        if ac ~= bc then return ac < bc end
        return tostring(a.source_name or "") < tostring(b.source_name or "")
    end)
    return results, errors
end


function BookService:resolveCoverCandidates(book, results, progress_callback)
    local covers, errors = {}, {}
    for index, result in ipairs(results or {}) do
        local candidate = result
        if tostring(candidate.cover or "") == "" then
            local source = sourceForCandidate(candidate)
            if source then
                local info, err = LegadoSource:getBookInfo(source, candidate)
                if info then
                    info.source_id = source.id
                    info.source_name = source.name
                    info.author_mismatch = BookIdentity:authorDiffers(book.author, info.author)
                    info.title_mismatch = not sameBookIdentity(book, info)
                    candidate = info
                elseif err then
                    errors[#errors + 1] = tostring(source.name) .. ": " .. tostring(err)
                end
            end
        end
        if tostring(candidate.cover or "") ~= "" then covers[#covers + 1] = candidate end
        if progress_callback then pcall(progress_callback, index, #(results or {}), "补全封面 " .. tostring(index) .. "/" .. tostring(#(results or {}))) end
    end
    Storage:releaseSourceSettings()
    return covers, errors
end

local function activeSourceProfile(book, toc_ref)
    return {
        source_id = book.source_id,
        source_name = book.source_name,
        book_url = book.book_url,
        toc_url = book.toc_url,
        detail_resolved = book.detail_resolved == true,
        variables = book.variables,
        content_cover = book.content_cover or book.cover,
        toc_ref = toc_ref,
        position = Util.positionCopy(book.position),
        saved_at = os.time(),
    }
end

local function profileKey(source_id, book_url)
    return tostring(source_id or "") .. "|" .. tostring(book_url or "")
end

local function closestChapterIndex(chapters, old_title, old_index, old_count)
    local wanted = BookIdentity:normalizeTitle(old_title)
    if wanted ~= "" then
        for index, chapter in ipairs(chapters or {}) do
            if BookIdentity:normalizeTitle(chapter.title) == wanted then return index end
        end
    end
    local count = #(chapters or {})
    if count == 0 then return 1 end
    if old_count and old_count > 1 and old_index then
        local ratio = math.max(0, math.min(1, (old_index - 1) / (old_count - 1)))
        return math.max(1, math.min(count, math.floor(ratio * (count - 1) + 1.5)))
    end
    return math.max(1, math.min(count, tonumber(old_index) or 1))
end

function BookService:switchContentSource(book, result, progress_callback, options)
    if not book or not result then return nil, "换源参数不完整" end
    options = options or {}
    local source = sourceForCandidate(result)
    if not source then return nil, "目标书源不存在" end
    applyCandidateRuntime(source, result)
    -- Search candidates keep runtime state in memory. During the selected-source
    -- transaction, defer cookie/variable persistence and commit it once after
    -- the final book+TOC write succeeds.
    source._suppress_runtime_persist = true
    local function fail(message)
        source._suppress_runtime_persist = nil
        Storage:releaseSourceSettings()
        return nil, message
    end

    -- Switching sources consumes the same unresolved search-candidate type as
    -- normal opening. Resolve it through ruleBookInfo first; never commit or
    -- preflight a candidate tocUrl directly.
    local function phaseProgress(first, span, fallback)
        return rangedProgress(progress_callback, first, span, fallback)
    end
    if progress_callback then progress_callback(5, "获取目标书源详情", 100) end
    local info, info_err, detail_warning = resolveCandidateInfo(source, result, {
        on_progress = phaseProgress(5, 15, "获取目标书源详情"),
    })
    if not info then return fail(info_err) end
    info.detail_resolved = true

    local identity_warning = detailIdentityWarning(book, info) or detail_warning
    if progress_callback then progress_callback(25, "读取目标目录", 100) end
    local toc, toc_err = LegadoSource:getToc(source, info, {
        cache_read = true,
        cache_write = false,
        save_runtime = false,
        on_progress = phaseProgress(25, 50, "读取目标目录"),
    })
    if not toc or #toc == 0 then
        return fail("目录请求失败：" .. tostring(toc_err or "目标目录为空"))
    end

    local old_chapters = book.chapters or {}
    local old_position = Util.positionCopy(book.position)
    local old_state = {
        toc_checked_at = book.toc_checked_at,
        toc_check_attempted_at = book.toc_check_attempted_at,
        toc_check_status = book.toc_check_status,
        toc_check_error = book.toc_check_error,
        toc_last_new_count = book.toc_last_new_count,
        toc_update_count = book.toc_update_count,
        toc_update_latest_title = book.toc_update_latest_title,
        updated_at = book.updated_at,
    }
    local old_toc_bytes = type(Storage.getBookTocPath) == "function"
        and Util.readFile(Storage:getBookTocPath(book.id), true) or nil
    local old_index = math.max(1, math.min(#old_chapters,
        tonumber(book.position and book.position.chapter) or 1))
    local old_title = old_chapters[old_index] and old_chapters[old_index].title or nil
    local profiles = book.content_source_profiles or {}
    local target_key = profileKey(source.id, info.book_url or result.book_url)
    local saved = profiles[target_key]
    local saved_chapters = saved
        and (saved.chapters or Storage:loadBookProfileToc(book.id, saved.toc_ref or target_key)) or nil
    local new_chapters = toc
    if type(saved_chapters) == "table" then
        new_chapters = mergeChapterState(saved_chapters, toc)
    end
    local new_index = closestChapterIndex(new_chapters, old_title, old_index, #old_chapters)

    -- Build the target book separately and, when requested, prove that its
    -- current chapter can be read before touching the active book/profile.
    -- This makes switching atomic from the UI's point of view and prevents the
    -- ReaderView callback from falling back to network I/O on the UI thread.
    local candidate = {}
    for key, value in pairs(book) do candidate[key] = value end
    candidate.source_id = source.id
    candidate.source_name = source.name
    candidate.source_record = result._source_record
    candidate.book_url = info.book_url or result.book_url
    candidate.toc_url = info.toc_url
    candidate.detail_resolved = true
    candidate.variables = info.variables or result.variables or {}
    candidate._search_base_url = result._search_base_url
    for _, key in ipairs({ "toc_html", "_detail_base_url", "_detail_response_url", "_detail_request_base_url",
        "_detail_content_type", "_detail_code", "_detail_status" }) do
        if info[key] ~= nil then candidate[key] = info[key] end
    end
    -- A content-source switch must not erase the last usable cover merely
    -- because the target source has no cover rule or returned an empty value.
    -- The persisted local cover_path remains authoritative when present; this
    -- fallback also keeps remote-cover reload available for trial books.
    candidate.toc_node_count, candidate.toc_list_signature = info.toc_node_count, info.toc_list_signature
    candidate.content_cover = boundedCover(info.cover)
        or boundedCover(result.cover)
        or boundedCover(book.content_cover) or boundedCover(book.cover)
    candidate.cover = candidate.content_cover
    candidate.chapters = new_chapters
    markTocSuccess(candidate, old_chapters, toc)
    candidate.position = {
        chapter = new_index,
        chapter_id = new_chapters[new_index] and new_chapters[new_index].id or nil,
        paragraph = math.max(1, tonumber(old_position and old_position.paragraph) or 1),
        char = math.max(1, tonumber(old_position and old_position.char) or 1),
    }

    local target_file_rollback
    if options.prepare_chapter == true then
        local inline_response_consumed = false
        if progress_callback then progress_callback(80, "验证目标源当前章节", 100) end
        local current = new_chapters[new_index]
        if not current then return fail("目标目录没有可读取章节") end
        local exists, path = chapterOnDisk(candidate, new_index)
        -- A source switch is a source-verification operation, not a cache hit:
        -- always fetch and parse the target source's current chapter. Keep the
        -- old target file long enough to restore it if the later book commit
        -- fails, while Storage:saveChapter itself remains atomic.
        if exists then
            local old_content = Util.readFile(path, true)
            target_file_rollback = { path = path, content = old_content, existed = true }
        else
            target_file_rollback = { path = path, existed = false }
        end
        local content, content_err, consumed = LegadoSource:getContent(source, candidate, current, {
            on_progress = phaseProgress(80, 15, "验证目标源当前章节"),
        })
        if not content then
            return fail("目标源当前章节读取失败：" .. tostring(content_err or "未知错误"))
        end
        local saved_ok, save_err = Storage:saveChapter(candidate, new_index, content, {
            persist_metadata = false,
        })
        if not saved_ok then
            return fail("目标源当前章节保存失败：" .. tostring(save_err or "未知错误"))
        end
        -- The detail page is no longer needed once the chapter that could
        -- consume it has been durably written.
        inline_response_consumed = consumed == true
        if inline_response_consumed then
            -- Only a successfully saved chapter that actually selected the
            -- detail response completes this hand-off.
            clearInlineResponse(candidate)
        else
            -- Ordinary chapters may precede the detail-URL chapter. Keep the
            -- raw bytes in the bounded sidecar, never in the book model.
            local payload = inlineResponsePayload(candidate, source)
            if payload and not saveInlineResponse(candidate, source, candidate) then
                return fail("target source detail response could not be retained")
            end
            clearInlineResponseFields(candidate)
        end
    end

    -- Keep a response sidecar for a later first chapter when this operation is
    -- only selecting a source.  It is keyed by the target source/book URL and
    -- never enters book.lua.
    if options.prepare_chapter ~= true then saveInlineResponse(candidate, source, info) end

    -- Only after the target source is fully usable do we cancel current work,
    -- snapshot the old source profile, and commit the replacement. Keep an
    -- in-memory rollback image as well: UI state must never observe a half-applied
    -- source when a flash write or LuaSettings flush raises an error.
    local rollback_snapshot = BookSnapshot:capture(book)
    local previous_runtime_source = self._runtime_sources[tostring(book.id)]
    self:cancelPrefetch(book.id, true)
    self:clearBookCache(book.id)
    local committed, commit_err = xpcall(function()
        book.content_source_profiles = profiles
        if book.source_id and book.book_url then
            local current_key = profileKey(book.source_id, book.book_url)
            local profile_ok, profile_err = Storage:saveBookProfileToc(book.id, current_key, old_chapters)
            if profile_ok ~= true then error(tostring(profile_err or "原内容源目录快照保存失败")) end
            profiles[current_key] = activeSourceProfile(book, current_key)
        end

        book.source_id = candidate.source_id
        book.source_name = candidate.source_name
        book.source_record = candidate.source_record
        book.book_url = candidate.book_url
        book.toc_url = candidate.toc_url
        clearInlineResponseFields(book)
        book.detail_resolved = true
        book.variables = candidate.variables
        book._search_base_url = candidate._search_base_url
        book.toc_node_count, book.toc_list_signature = candidate.toc_node_count, candidate.toc_list_signature
        book.toc_pending, book.toc_pending_added = nil, nil
        book.content_cover = candidate.content_cover
        book.cover = candidate.cover
        book.chapters = candidate.chapters
        book.position = candidate.position
        book.toc_checked_at = candidate.toc_checked_at
        book.toc_check_status = candidate.toc_check_status
        book.toc_check_error = candidate.toc_check_error
        book.toc_last_new_count = candidate.toc_last_new_count
        book.toc_update_count = candidate.toc_update_count
        book.toc_update_latest_title = candidate.toc_update_latest_title
        book.updated_at = os.time()
        book._toc_dirty = true
        -- The active source already owns toc.lua. Do not duplicate the same large
        -- directory into source-tocs/ until this source is actually left.
        profiles[target_key] = activeSourceProfile(book, target_key)
        self._runtime_sources[tostring(book.id)] = source
        local save_ok, save_err = Storage:saveBook(book, {
            force_summary = Storage:isInLibrary(book.id), force_toc = true,
        })
        if save_ok ~= true then error(tostring(save_err or "书籍与目录保存失败")) end
        source._suppress_runtime_persist = nil
        local runtime_ok, runtime_err = Storage:saveSourceRuntime(source)
        if runtime_ok ~= true then error(tostring(runtime_err or "书源状态保存失败")) end
    end, function(err)
        return debug and debug.traceback and debug.traceback(tostring(err), 2) or tostring(err)
    end)
    if not committed then
        BookSnapshot:restore(book, rollback_snapshot)
        self._runtime_sources[tostring(book.id)] = previous_runtime_source
        if target_file_rollback and target_file_rollback.path then
            if target_file_rollback.existed and target_file_rollback.content then
                pcall(Util.writeFile, target_file_rollback.path, target_file_rollback.content)
            elseif not target_file_rollback.existed then
                pcall(os.remove, target_file_rollback.path)
            end
        end
        source._suppress_runtime_persist = nil
        -- Best-effort disk rollback. The storage layer already writes each Lua
        -- settings file independently; restoring the old snapshot keeps the next
        -- launch and the current UI on the same source profile.
        pcall(Storage.saveBook, Storage, book, {
            force_summary = Storage:isInLibrary(book.id), force_toc = true,
        })
        pcall(Storage.clearInlineBookResponse, Storage, book.id)
        Storage:releaseSourceSettings()
        return nil, "内容源提交失败，已恢复原书源：" .. tostring(commit_err)
    end
    Storage:releaseSourceSettings()
    if progress_callback then
        progress_callback(95,
            options.prepare_chapter == true and "内容源与当前章节已切换" or "内容源已切换", 100)
    end
    return book, nil, identity_warning
end

function BookService:setCoverFromSearchResult(book, result, source_override)
    if not book or not result then return nil, "封面换源参数不完整" end
    if tostring(result.cover or "") == "" then return nil, "这个结果没有封面" end
    local CoverService = require("Leko/CoverService")
    source_override = source_override or result._cover_source
    applyCandidateRuntime(source_override, result)
    local _, prepared, fetch_state = CoverService:fetch(result, 360, 520, source_override, { force = true })
    if not prepared or not prepared.body then return nil, fetch_state or "封面获取失败" end
    local ext = prepared.ext or (prepared.info and prepared.info.extension) or "jpg"
    local filename = tostring(book.id) .. "-selected-" .. Util.hashId(prepared.body) .. "." .. tostring(ext)
    local path = Util.joinPath(Storage:getCoversDir(), filename)
    local ok, write_err = Util.writeFile(path, prepared.body, true)
    if not ok then return nil, write_err end
    local valid, validate_err = rememberWrittenCover(self, path)
    if not valid then os.remove(path); return nil, validate_err end
    return commitCoverState(self, book, path, function(target)
        target.cover_path = path
        target.manual_cover = nil
        target.selected_cover_url = result.cover
        target.cover_source_id = result.source_id
        target.cover_source_name = result.source_name
        target.cover_source_record = result._source_record
        target.cover_book_url = result.book_url
        target.cover_variables = result.variables
        target.updated_at = os.time()
    end, source_override)
end

function BookService:checkToc(book, progress_callback)
    if not book.toc_node_count or not book.toc_list_signature then
        if #(book.chapters or {}) == 0 then book.chapters = Storage:loadBookToc(book.id) or {} end
        return self:refreshToc(book, progress_callback)
    end
    local source = self:sourceFor(book)
    if not source then return nil, "书源不存在" end
    local probe, err = LegadoSource:getToc(source, book, {
        check_only=true, prepare_update=true, cache_read=false, cache_write=false, run_per_js=true,
        existing_chapters=function()
            if #(book.chapters or {}) == 0 then book.chapters = Storage:loadBookToc(book.id) or {} end
            return book.chapters
        end,
        on_progress=rangedProgress(progress_callback, 10, 75, "检查目录变化"),
    })
    if not probe then persistTocFailure(book, err); return nil, err end
    if probe.chapters then
        -- The check already fetched and parsed this exact remote catalogue.
        -- Commit it once here; opening the book now consumes the local TOC.
        if #(book.chapters or {}) == 0 then book.chapters = Storage:loadBookToc(book.id) or {} end
        return self:refreshToc(book, progress_callback, probe)
    end
    local changed = probe.count ~= book.toc_node_count or probe.signature ~= book.toc_list_signature
    local added = changed and math.max(0, probe.count - book.toc_node_count) or 0
    book.toc_update_count = math.max(0, (book.toc_update_count or 0) - (book.toc_pending_added or 0)) + added
    book.toc_pending, book.toc_pending_added = changed or nil, added
    book.toc_checked_at, book.toc_check_attempted_at = os.time(), os.time()
    book.toc_check_status, book.toc_check_error = "ok", nil
    local saved, save_err = Storage:saveBook(book, {save_toc=false, save_progress=false})
    if not saved then return nil, tostring(save_err or "检查结果保存失败") end
    return book, nil, {new_count=added, changed=changed, checked_at=book.toc_checked_at}
end

function BookService:refreshToc(book, progress_callback, prepared)
    if not book.source_id then
        persistTocFailure(book, "本地书籍没有远程目录")
        return nil, "本地书籍没有远程目录"
    end
    local source = self:sourceFor(book)
    if not source then
        persistTocFailure(book, "书源不存在")
        return nil, "书源不存在"
    end
    -- A source switch or reopened search candidate may have a bounded detail
    -- response waiting for the first TOC/content consumer. Present it to the
    -- parser before this foreground refresh invalidates the hand-off.
    hydrateInlineResponse(book)
    -- A user-triggered TOC refresh is the production equivalent of
    -- WebBook.getChapterListAwait(..., runPerJs = true).  Keep the lower
    -- parser opt-in explicit, but do not omit the production preUpdateJs hook
    -- from this foreground refresh path.
    local old_state = {}
    for _, key in ipairs({"toc_node_count", "toc_list_signature", "toc_pending", "toc_pending_added",
        "toc_update_count", "toc_checked_at", "toc_check_attempted_at", "toc_check_status",
        "toc_check_error", "toc_last_new_count", "toc_update_latest_title", "updated_at"}) do
        if book[key] == nil then old_state[key] = false else old_state[key] = book[key] end
    end
    local old_toc_bytes = type(Storage.getBookTocPath) == "function"
        and Util.readFile(Storage:getBookTocPath(book.id), true) or nil
    local new_chapters, err
    if prepared then
        new_chapters = prepared.chapters
        book.toc_node_count, book.toc_list_signature = prepared.count, prepared.signature
    else
    new_chapters, err = LegadoSource:getToc(source, book, {
        cache_read = false, cache_write = false, reuse_inline_response = false,
        force_toc_parse = true,
        run_per_js = true,
        on_progress = rangedProgress(progress_callback, 10, 75, "刷新章节目录"),
    })
    end
    if not new_chapters then
        persistTocFailure(book, err)
        return nil, err
    end
    if #new_chapters == 0 then
        persistTocFailure(book, "目录为空")
        return nil, "目录为空"
    end

    local old_chapters = book.chapters or {}
    local old_position = Util.positionCopy(book.position)
    local old_position_id = book.position and book.position.chapter_id
    if not old_position_id and book.position and book.chapters and book.chapters[book.position.chapter] then
        old_position_id = book.chapters[book.position.chapter].id
    end
    book.chapters = mergeChapterState(old_chapters, new_chapters)
    book.toc_update_count = math.max(0, (book.toc_update_count or 0) - (book.toc_pending_added or 0))
    book.toc_pending, book.toc_pending_added = nil, nil
    local new_count, latest_title = markTocSuccess(book, old_chapters, new_chapters)
    book._toc_dirty = true
    book.updated_at = os.time()
    book.position = book.position or { chapter = 1, paragraph = 1, char = 1 }
    if old_position_id then
        for index, chapter in ipairs(book.chapters) do
            if chapter.id == old_position_id then
                book.position.chapter = index
                book.position.chapter_id = old_position_id
                break
            end
        end
    end
    if book.position.chapter > #book.chapters then book.position.chapter = #book.chapters end
    local current = book.chapters[book.position.chapter]
    book.position.chapter_id = current and current.id or nil
    -- A TOC refresh can parse a detail response without being the content
    -- consumer. Keep the sidecar until getContent reports actual reuse.
    clearInlineResponseFields(book)
    local saved, save_result = pcall(Storage.saveBook, Storage, book)
    if not saved or save_result ~= true then
        -- The parser result was valid but persistence failed. Restore the
        -- in-memory directory and leave the previous on-disk TOC authoritative.
        book.chapters = old_chapters
        book.chapter_count = #old_chapters
        book.toc_ready = #old_chapters > 0
        book.position = old_position
        for key, value in pairs(old_state) do book[key] = value ~= false and value or nil end
        if old_toc_bytes and type(Storage.getBookTocPath) == "function" then
            pcall(Util.writeFile, Storage:getBookTocPath(book.id), old_toc_bytes, true)
        end
        persistTocFailure(book, save_result)
        return nil, "目录保存失败：" .. tostring(save_result)
    end
    return book, nil, {
        new_count = new_count,
        latest_title = latest_title,
        checked_at = book.toc_checked_at,
        changed = prepared ~= nil and true or nil,
    }
end

function BookService:ensureChapter(book, chapter_index, options)
    options = options or {}
    chapter_index = tonumber(chapter_index)
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return nil, "章节不存在" end

    -- Chapter text is a persistent disk cache. The in-memory model LRU is only
    -- an optional acceleration layer and is intentionally lost on exit.
    local exists, path = chapterOnDisk(book, chapter_index)
    if exists and options.force_network ~= true then
        chapter.path = path
        chapter.downloaded = true
        return Storage:loadChapter(book, chapter_index)
    end

    if not book.source_id or not chapter.url then return nil, "章节尚未下载，且没有远程地址" end
    local source = self:sourceFor(book)
    if not source then return nil, "书源不存在" end
    hydrateInlineResponse(book)
    local content, err, inline_response_consumed = LegadoSource:getContent(source, book, chapter, {
        on_progress = options.on_progress,
    })
    if not content then return nil, err end
    local ok, save_err = Storage:saveChapter(book, chapter_index, content, {
        persist_metadata = false,
    })
    if not ok then return nil, save_err end
    -- Once the chapter is on disk the detail response hand-off has completed;
    -- remove both its raw bytes and transient fields.
    if inline_response_consumed == true then
        -- The saved chapter consumed the detail response, so its hand-off is
        -- complete and both the bytes and transient fields can be removed.
        clearInlineResponse(book)
    else
        -- A normal chapter must not make a later detail-URL chapter re-request
        -- or lose the response. Drop only the hydrated model fields.
        clearInlineResponseFields(book)
    end
    return content
end

-- Prepare only the chapter required to enter the reader. The foreground
-- subprocess downloads/writes the chapter, but deliberately does not build the
-- paragraph/page model; that keeps the pipe tiny and avoids duplicating a large
-- Lua model in both parent and child.
function BookService:prepareReading(book, chapter_index, progress_callback)
    if not book then return nil, "book required" end
    if progress_callback then progress_callback(2, "检查书籍详情与目录", 100) end
    local ready_book, toc_err = self:ensureToc(book, progress_callback)
    if not ready_book then return nil, toc_err end
    book = ready_book
    local count = #(book.chapters or {})
    if count == 0 then return nil, "目录为空" end
    chapter_index = math.max(1, math.min(count, tonumber(chapter_index
        or (book.position and book.position.chapter) or 1) or 1))
    if progress_callback then progress_callback(82, "准备当前章节", 100) end
    local content, err = self:ensureChapter(book, chapter_index, {
        on_progress = rangedProgress(progress_callback, 82, 13, "准备当前章节"),
    })
    if not content then return nil, err end
    local chapter = book.chapters[chapter_index]
    local previous = Util.positionCopy(book.position)
    local same_chapter = previous.chapter == chapter_index
    -- A legacy progress file may not have chapter_id; the numeric chapter is
    -- still useful. If both IDs exist, however, a replacement chapter must
    -- never inherit the old chapter's paragraph/character cursor.
    if same_chapter and previous.chapter_id ~= nil
            and tostring(previous.chapter_id) ~= tostring(chapter and chapter.id) then
        same_chapter = false
    end
    book.position = {
        chapter = chapter_index,
        chapter_id = chapter and chapter.id or nil,
        paragraph = same_chapter and previous.paragraph or 1,
        char = same_chapter and previous.char or 1,
    }
    -- Entering the reader only prepares memory. The reader persists the
    -- position once when its page is closed, avoiding flash writes here.
    if progress_callback then progress_callback(95, "当前章节已准备", 100) end
    local warning = book._identity_warning
    book._identity_warning = nil
    return book, nil, warning
end

local function buildChapterModel(service, book, chapter_index, content)
    local chapter = book.chapters[chapter_index]
    local model = {
        index = chapter_index,
        id = chapter.id,
        title = chapter.title or ("第 " .. chapter_index .. " 章"),
        paragraphs = Util.splitParagraphs(content),
    }
    if #model.paragraphs == 0 then model.paragraphs = { "（本章为空）" } end
    service:_putCache(book, chapter_index, model)
    return model
end

-- UI pagination is a pure local operation. A missing chapter is reported to the
-- ReadingCoordinator instead of silently turning layout into a network request.
function BookService:loadChapterModel(book, chapter_index)
    local key = cacheKey(book.id, chapter_index)
    local cached = self._chapter_cache[key]
    if cached then return cached end
    local chapter = book.chapters and book.chapters[chapter_index]
    if not chapter then return nil, "章节不存在" end
    -- Reopening a book starts here: disk is authoritative, so a lost RAM model
    -- must not be mistaken for a missing/downloadable chapter.
    local exists, path = chapterOnDisk(book, chapter_index)
    if not exists then return nil, "章节尚未下载" end
    chapter.path = path
    chapter.downloaded = true
    local content, err = Storage:loadChapter(book, chapter_index)
    if not content then return nil, err end
    return buildChapterModel(self, book, chapter_index, content)
end

-- Domain/background callers may still explicitly prepare a model from a remote
-- chapter. ReaderView and Paginator never call this network-capable method.
function BookService:getChapterModel(book, chapter_index)
    local cached = self._chapter_cache[cacheKey(book.id, chapter_index)]
    if cached then return cached end
    local content, err = self:ensureChapter(book, chapter_index)
    if not content then return nil, err end
    return buildChapterModel(self, book, chapter_index, content)
end

function BookService:markTocUpdateSeen(book)
    if type(book) ~= "table" or not book.id then return false end
    if tonumber(book.toc_update_count or 0) == 0
            and book.toc_update_latest_title == nil then return false end
    book.toc_update_count = 0
    book.toc_update_latest_title = nil
    book.toc_last_new_count = 0
    pcall(Storage.saveBook, Storage, book, {
        save_toc = false,
        save_progress = false,
        force_summary = Storage:isInLibrary(book.id),
    })
    return true
end

function BookService:savePosition(book, position, flush)
    if type(book) ~= "table" then return false, "book is required" end
    book.position = Util.positionCopy(position)
    local chapter = book.chapters and book.chapters[book.position.chapter]
    book.position.chapter_id = chapter and chapter.id or nil
    book.last_read_at = os.time()
    if flush ~= false then return Storage:saveBookProgress(book) end
    return true
end

function BookService:bindRuntimeSource(book)
    if not book or not book.id or not book.source_id then return nil end
    local source = self:sourceFor(book)
    return source
end

function BookService:releaseRuntimeSource(book_id)
    book_id = tostring(book_id)
    self._runtime_sources[book_id] = nil
    local cover_prefix = "cover:" .. book_id .. ":"
    for key in pairs(self._runtime_sources) do
        if key:sub(1, #cover_prefix) == cover_prefix then self._runtime_sources[key] = nil end
    end
end

function BookService:isChapterDownloaded(book, chapter_index)
    local exists, path = chapterOnDisk(book, chapter_index)
    if exists then
        local chapter = book.chapters[chapter_index]
        chapter.path = path
        chapter.downloaded = true
        return true
    end
    return false
end

-- Rehydrate the in-memory TOC from the deterministic chapter files in one
-- directory pass.  This is both faster than one stat() per row on large books
-- and fixes the first-open mismatch where the footer knew a prefetch window was
-- cached but a freshly loaded TOC still contained downloaded=false.
function BookService:refreshChapterDownloadStates(book)
    if type(book) ~= "table" or not book.id then return 0, 0 end
    local chapters = book.chapters or {}
    local chapter_dir = Storage:getChapterDir(book.id)
    local filenames = {}
    if lfs.attributes(chapter_dir, "mode") == "directory" then
        local ok, iterator, directory = pcall(lfs.dir, chapter_dir)
        if ok and iterator then
            for name in iterator, directory do
                if name ~= "." and name ~= ".." then filenames[name] = true end
            end
        end
    end
    local cached = 0
    for index, chapter in ipairs(chapters) do
        local expected = Storage:getChapterPath(book.id, index, chapter.id)
        local present = filenames[Util.basename(expected)] == true
        local path = expected
        if not present and chapter.path and chapter.path ~= expected
                and lfs.attributes(chapter.path, "mode") == "file" then
            present, path = true, chapter.path
        end
        chapter.downloaded = present
        if present then chapter.path = path; cached = cached + 1 end
    end
    return cached, #chapters
end

function BookService:getPrefetchState(book_id)
    return self._prefetch_states[tostring(book_id)]
end

function BookService:observePrefetch(book_id, owner, callback)
    book_id = tostring(book_id)
    local observers = self._prefetch_observers[book_id]
    if not observers then
        observers = setmetatable({}, { __mode = "k" })
        self._prefetch_observers[book_id] = observers
    end
    observers[owner] = callback
    local state = self._prefetch_states[book_id]
    if state then pcall(callback, state) end
end

function BookService:unobservePrefetch(book_id, owner)
    local observers = self._prefetch_observers[tostring(book_id)]
    if observers then observers[owner] = nil end
end

function BookService:_notifyPrefetch(state)
    local observers = self._prefetch_observers[state.book_id]
    if not observers then return end
    for _, callback in pairs(observers) do pcall(callback, state) end
end

local function countIndicesDownloaded(self, book, indices)
    local downloaded = 0
    for _, index in ipairs(indices or {}) do
        if self:isChapterDownloaded(book, index) then downloaded = downloaded + 1 end
    end
    return downloaded
end

local function buildPrefetchIndices(chapter_count, current_index, forward_count, backward_count)
    local result, seen = {}, {}
    local function add(index)
        if index >= 1 and index <= chapter_count and index ~= current_index and not seen[index] then
            seen[index] = true
            result[#result + 1] = index
        end
    end
    -- Interleave the nearest chapters first. This makes both the common next
    -- chapter transition and a quick backtrack responsive on slow Kindles.
    local nearest = math.max(forward_count, backward_count)
    for distance = 1, nearest do
        if distance <= forward_count then add(current_index + distance) end
        if distance <= backward_count then add(current_index - distance) end
    end
    return result
end

BookService._buildPrefetchIndices = buildPrefetchIndices

local function scheduleWorkerReap(worker)
    if worker then AsyncChapterPrefetch:cancel(worker) end
end

function BookService:cancelPrefetch(book_id, keep_status)
    book_id = tostring(book_id)
    local state = self._prefetch_states[book_id]
    if not state then return end
    state.generation = (state.generation or 0) + 1
    state.active = false
    state.queue = nil
    state.book = nil
    state.target_index = nil
    state.target_title = nil
    if state.worker then
        scheduleWorkerReap(state.worker)
        state.worker = nil
    end
    if not keep_status then state.status = "paused" end
    self:_notifyPrefetch(state)
end

function BookService:_finishPrefetchWindow(state, book)
    state.active = false
    state.worker = nil
    state.target_index = nil
    state.target_title = nil
    state.cached = countIndicesDownloaded(self, book or {}, state.window_indices)
    state.status = state.failed > 0 and "partial" or "ready"
    -- Chapter files use deterministic paths and are discovered from disk. A
    -- completed prefetch window therefore needs no metadata write at all.
    self:_notifyPrefetch(state)
end

function BookService:_prefetchStep(book_id, generation)
    local state = self._prefetch_states[book_id]
    if not state or state.generation ~= generation or not state.active or state.worker then return end
    local book = state.book
    local index = state.queue and table.remove(state.queue, 1)
    if not book or not index then
        self:_finishPrefetchWindow(state, book)
        return
    end

    local chapter = book.chapters[index]
    if not chapter then
        state.failed = state.failed + 1
        state.last_error = "章节不存在"
        UIManager:scheduleIn(self.prefetch_step_delay, function()
            self:_prefetchStep(book_id, generation)
        end)
        return
    end

    local source = self:sourceFor(book)
    if not source then
        state.failed = state.failed + 1
        state.last_error = "书源不存在"
        UIManager:scheduleIn(self.prefetch_step_delay, function()
            self:_prefetchStep(book_id, generation)
        end)
        return
    end

    state.status = "downloading"
    state.target_index = index
    state.target_title = chapter.title or ("第 " .. index .. " 章")
    self:_notifyPrefetch(state)

    local final_path = Storage:getChapterPath(book.id, index, chapter.id)
    local worker, spawn_err = AsyncChapterPrefetch:start({
        source = source,
        book = book,
        chapter_index = index,
        final_path = final_path,
    }, function(ok, err, completed_worker, result)
        local current = self._prefetch_states[book_id]
        if not current or current.generation ~= generation or not current.active then return end
        if current.worker ~= completed_worker then return end
        current.worker = nil
        -- The child may have updated source cookies/variables on disk. Drop the
        -- inherited in-memory copy so the next request hydrates the latest state.
        self._runtime_sources[book_id] = nil

        if ok then
            chapter.path = final_path
            chapter.downloaded = true
            chapter.updated_at = os.time()
            book.updated_at = os.time()
            if result and type(result.book_variables) == "table" then book.variables = result.book_variables end
            if result and type(result.chapter_variables) == "table" then chapter.variables = result.chapter_variables end
        elseif result and result.preempted then
            -- Foreground interaction always wins. Put this chapter back at the
            -- front of the queue without counting it as a failure, and retry only
            -- after the foreground process has released the global budget.
            table.insert(current.queue, 1, index)
            current.status = "waiting"
            current.target_index = index
            current.target_title = chapter.title or ("第 " .. tostring(index) .. " 章")
            current.last_error = nil
            self:_notifyPrefetch(current)
            UIManager:scheduleIn(math.max(0.8, self.prefetch_step_delay), function()
                self:_prefetchStep(book_id, generation)
            end)
            return
        else
            current.failed = current.failed + 1
            current.last_error = tostring(err or "章节预缓存失败")
        end
        current.cached = countIndicesDownloaded(self, book, current.window_indices)
        self:_notifyPrefetch(current)
        UIManager:scheduleIn(self.prefetch_step_delay, function()
            self:_prefetchStep(book_id, generation)
        end)
    end)

    if not worker then
        state.failed = state.failed + 1
        state.last_error = tostring(spawn_err or "无法启动后台预缓存")
        state.status = "partial"
        self:_notifyPrefetch(state)
        UIManager:scheduleIn(self.prefetch_step_delay, function()
            self:_prefetchStep(book_id, generation)
        end)
        return
    end
    state.worker = worker
end

function BookService:requestPrefetch(book, current_index, forward_count, backward_count)
    if not book or not book.id or not book.source_id then return nil end
    local chapter_count = #(book.chapters or {})
    if chapter_count == 0 then return nil end
    current_index = math.max(1, math.min(chapter_count, tonumber(current_index) or 1))
    forward_count = math.max(0, tonumber(forward_count) or self.prefetch_forward_window or self.prefetch_window)
    backward_count = math.max(0, tonumber(backward_count) or self.prefetch_backward_window)
    local indices = buildPrefetchIndices(chapter_count, current_index, forward_count, backward_count)
    local signature = table.concat(indices, ",")
    local book_id = tostring(book.id)
    local state = self._prefetch_states[book_id] or { book_id = book_id, generation = 0 }
    self._prefetch_states[book_id] = state

    if state.book == book and state.current_chapter == current_index and state.window_signature == signature
            and (state.active or state.status == "ready" or state.status == "partial") then
        return state
    end

    if state.worker then
        scheduleWorkerReap(state.worker)
        state.worker = nil
    end
    state.generation = (state.generation or 0) + 1
    local generation = state.generation
    state.book = book
    state.active = false
    state.current_chapter = current_index
    state.window_indices = indices
    state.window_signature = signature
    state.first_index = math.max(1, current_index - backward_count)
    state.last_index = math.min(chapter_count, current_index + forward_count)
    state.total = #indices
    state.cached = countIndicesDownloaded(self, book, indices)
    state.failed = 0
    state.last_error = nil
    state.prefetched_until = state.last_index
    state.cached_before = 0
    state.cached_after = 0
    state.queue = {}
    for _, index in ipairs(indices) do
        if self:isChapterDownloaded(book, index) then
            if index < current_index then state.cached_before = state.cached_before + 1
            else state.cached_after = state.cached_after + 1 end
        else
            state.queue[#state.queue + 1] = index
        end
    end

    if #indices == 0 then
        state.status = "end"
        self:_notifyPrefetch(state)
        return state
    end
    if #state.queue == 0 then
        state.status = "ready"
        self:_notifyPrefetch(state)
        return state
    end

    state.active = true
    state.status = "waiting"
    state.target_index = state.queue[1]
    local target = book.chapters[state.target_index]
    state.target_title = target and target.title or nil
    self:_notifyPrefetch(state)
    UIManager:scheduleIn(self.prefetch_start_delay, function()
        self:_prefetchStep(book_id, generation)
    end)
    return state
end

-- Backward-compatible entry point. The disk window now includes two chapters
-- behind the current position and five ahead, while paragraph models stay RAM-bound.
function BookService:prefetchAdjacent(book, chapter_index)
    return self:requestPrefetch(book, chapter_index, self.prefetch_forward_window, self.prefetch_backward_window)
end

function BookService:getFullCacheState(book_id)
    return self._full_cache_states[tostring(book_id)]
end

function BookService:observeFullCache(book_id, owner, callback)
    book_id = tostring(book_id)
    local observers = self._full_cache_observers[book_id]
    if not observers then
        observers = setmetatable({}, { __mode = "k" })
        self._full_cache_observers[book_id] = observers
    end
    observers[owner] = callback
    local state = self._full_cache_states[book_id]
    if state then pcall(callback, state) end
end

function BookService:unobserveFullCache(book_id, owner)
    local observers = self._full_cache_observers[tostring(book_id)]
    if observers then observers[owner] = nil end
end

function BookService:_notifyFullCache(state)
    local observers = state and self._full_cache_observers[state.book_id]
    if not observers then return end
    for _, callback in pairs(observers) do pcall(callback, state) end
end

local function fullCacheQueue(self, book)
    local total = #(book.chapters or {})
    local current = math.max(1, math.min(total,
        tonumber(book.position and book.position.chapter or 1) or 1))
    local queue = {}
    local function add(index)
        if index >= 1 and index <= total and not self:isChapterDownloaded(book, index) then
            queue[#queue + 1] = index
        end
    end
    -- Current/next chapters are useful first if the user starts reading while
    -- the whole-book job is still running; the remaining prefix follows.
    add(current)
    for index = current + 1, total do add(index) end
    for index = 1, current - 1 do add(index) end
    return queue
end

function BookService:_finishFullCache(state)
    state.active = false
    state.paused = false
    state.worker = nil
    state.target_index = nil
    state.target_title = nil
    state.cached, state.total = self:refreshChapterDownloadStates(state.book or {})
    state.status = state.cached >= state.total and state.total > 0 and "ready" or "partial"
    self:_notifyFullCache(state)
end

function BookService:_fullCacheStep(book_id, generation)
    local state = self._full_cache_states[book_id]
    if not state or state.generation ~= generation or not state.active or state.worker then return end
    local book = state.book
    local index = state.queue and table.remove(state.queue, 1)
    if not book or not index then self:_finishFullCache(state); return end
    local chapter = book.chapters and book.chapters[index]
    if not chapter then
        state.failed = (state.failed or 0) + 1
        state.last_error = "章节不存在"
        UIManager:scheduleIn(self.full_cache_step_delay, function()
            self:_fullCacheStep(book_id, generation)
        end)
        return
    end
    local source = self:sourceFor(book)
    if not source then
        state.failed = (state.failed or 0) + 1
        state.last_error = "书源不存在"
        UIManager:scheduleIn(self.full_cache_step_delay, function()
            self:_fullCacheStep(book_id, generation)
        end)
        return
    end

    state.status = "downloading"
    state.target_index = index
    state.target_title = chapter.title or ("第 " .. tostring(index) .. " 章")
    self:_notifyFullCache(state)
    local final_path = Storage:getChapterPath(book.id, index, chapter.id)
    local worker, spawn_err = AsyncChapterPrefetch:start({
        source = source,
        book = book,
        chapter_index = index,
        final_path = final_path,
        priority = 2,
        label = "full-book-cache",
        timeout_seconds = 32,
    }, function(ok, err, completed_worker, result)
        local current = self._full_cache_states[book_id]
        if not current or current.generation ~= generation or not current.active
                or current.worker ~= completed_worker then return end
        current.worker = nil
        self._runtime_sources[book_id] = nil
        if ok then
            chapter.path = final_path
            chapter.downloaded = true
            chapter.updated_at = os.time()
            book.updated_at = os.time()
            current.cached = math.min(current.total, (tonumber(current.cached) or 0) + 1)
            if result and type(result.book_variables) == "table" then book.variables = result.book_variables end
            if result and type(result.chapter_variables) == "table" then chapter.variables = result.chapter_variables end
            current.last_error = nil
        elseif result and result.preempted then
            table.insert(current.queue, 1, index)
            current.status = "waiting"
            current.last_error = nil
            self:_notifyFullCache(current)
            UIManager:scheduleIn(math.max(1.0, self.full_cache_step_delay), function()
                self:_fullCacheStep(book_id, generation)
            end)
            return
        else
            current.failed = (current.failed or 0) + 1
            current.last_error = tostring(err or "章节缓存失败")
        end
        self:_notifyFullCache(current)
        UIManager:scheduleIn(self.full_cache_step_delay, function()
            self:_fullCacheStep(book_id, generation)
        end)
    end)
    if not worker then
        state.failed = (state.failed or 0) + 1
        state.last_error = tostring(spawn_err or "无法启动整本缓存")
        state.status = "partial"
        self:_notifyFullCache(state)
        UIManager:scheduleIn(self.full_cache_step_delay, function()
            self:_fullCacheStep(book_id, generation)
        end)
        return
    end
    state.worker = worker
end

function BookService:startFullBookCache(book)
    if type(book) ~= "table" or not book.id then return nil, "书籍信息不完整" end
    if not book.source_id then return nil, "本地书籍无需联网缓存" end
    local total = #(book.chapters or {})
    if total == 0 then return nil, "请先读取章节目录" end
    local book_id = tostring(book.id)
    self:cancelPrefetch(book_id, true)
    local cached = self:refreshChapterDownloadStates(book)
    local state = self._full_cache_states[book_id] or { book_id = book_id, generation = 0 }
    self._full_cache_states[book_id] = state
    if state.worker then AsyncChapterPrefetch:cancel(state.worker); state.worker = nil end
    state.generation = (state.generation or 0) + 1
    local generation = state.generation
    state.book = book
    state.total = total
    state.cached = cached
    state.failed = 0
    state.last_error = nil
    state.queue = fullCacheQueue(self, book)
    state.target_index = nil
    state.target_title = nil
    state.paused = false
    if #state.queue == 0 then
        state.active = false
        state.status = "ready"
        self:_notifyFullCache(state)
        return state
    end
    state.active = true
    state.status = "waiting"
    self:_notifyFullCache(state)
    UIManager:scheduleIn(self.full_cache_start_delay, function()
        self:_fullCacheStep(book_id, generation)
    end)
    return state
end

function BookService:pauseFullBookCache(book_id)
    book_id = tostring(book_id)
    local state = self._full_cache_states[book_id]
    if not state then return false end
    state.generation = (state.generation or 0) + 1
    state.active = false
    state.paused = true
    state.status = "paused"
    if state.worker then AsyncChapterPrefetch:cancel(state.worker); state.worker = nil end
    state.target_index = nil
    state.target_title = nil
    if state.book then state.cached, state.total = self:refreshChapterDownloadStates(state.book) end
    self:_notifyFullCache(state)
    return true
end

function BookService:cancelFullBookCache(book_id)
    book_id = tostring(book_id)
    local state = self._full_cache_states[book_id]
    if state then
        state.generation = (state.generation or 0) + 1
        state.active = false
        if state.worker then AsyncChapterPrefetch:cancel(state.worker); state.worker = nil end
    end
    self._full_cache_states[book_id] = nil
    self._full_cache_observers[book_id] = nil
    return state ~= nil
end

function BookService:resumeFullBookCache(book)
    return self:startFullBookCache(book)
end

function BookService:getMemoryStats(book_id)
    local prefix = book_id and (tostring(book_id) .. ":") or nil
    local models, content_bytes, paragraph_bytes = 0, 0, 0
    for key, model in pairs(self._chapter_cache) do
        if not prefix or key:sub(1, #prefix) == prefix then
            models = models + 1
            for _, paragraph in ipairs(model.paragraphs or {}) do paragraph_bytes = paragraph_bytes + #paragraph end
        end
    end
    return {
        lua_kb = collectgarbage("count"),
        cached_models = models,
        content_bytes = content_bytes,
        paragraph_bytes = paragraph_bytes,
    }
end


return BookService
