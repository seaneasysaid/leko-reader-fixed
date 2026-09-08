-- Fifteen-minute, memory-only continuation data for source searches.  Rows are
-- deliberately reduced to presentation/request identifiers; response bodies,
-- QuickJS realms, cookies and login headers never enter this cache.
local SearchResultCache = { ttl_seconds = 15 * 60, entries = {} }

local function trim(value)
    return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function now() return os.time() end

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function safeVariables(value)
    if type(value) ~= "table" then return nil end
    local result = {}
    for key, item in pairs(value) do
        local name = tostring(key):lower()
        if not name:match("cookie") and not name:match("token") and not name:match("auth")
                and not name:match("password") and not name:match("header") and not name:match("session")
                and type(item) ~= "function" and (type(item) == "string" or type(item) == "number" or type(item) == "boolean") then
            result[key] = item
        end
    end
    return next(result) and result or nil
end

local function safeSourceRecord(value)
    if type(value) ~= "table" then return nil end
    local path = type(value.records_path) == "string" and value.records_path or nil
    local offset = tonumber(value.record_offset)
    local length = tonumber(value.record_length)
    if not path or not offset or not length then return nil end
    return { records_path = path, record_offset = offset, record_length = length }
end

local function compact(candidate)
    return {
        title = tostring(candidate and candidate.title or ""),
        author = tostring(candidate and candidate.author or ""),
        intro = tostring(candidate and candidate.intro or ""):sub(1, 512),
        book_url = candidate and candidate.book_url or nil,
        toc_url = candidate and candidate.toc_url or nil,
        cover = candidate and candidate.cover or nil,
        source_id = candidate and candidate.source_id or nil,
        source_name = candidate and candidate.source_name or nil,
        _search_base_url = candidate and candidate._search_base_url or nil,
        -- This compact index reference is what makes a restored row executable
        -- without retaining the source runtime, cookies or response body.
        _source_record = safeSourceRecord(candidate and candidate._source_record),
        variables = safeVariables(candidate and candidate.variables),
    }
end

function SearchResultCache:normalizeQuery(query)
    return trim(query):lower()
end

function SearchResultCache:scope(mode, book)
    if mode == "global" then return "global" end
    return tostring(mode or "content") .. ":" .. tostring(book and book.id or "")
end

function SearchResultCache:key(query, catalog_revision, source_ids)
    local ids = {}
    for _, source_id in ipairs(source_ids or {}) do ids[#ids + 1] = tostring(source_id) end
    table.sort(ids)
    return table.concat({ self:normalizeQuery(query), tostring(catalog_revision or ""), table.concat(ids, "\n") }, "\n---\n")
end

function SearchResultCache:_fresh(entry)
    return type(entry) == "table" and now() - (tonumber(entry.updated_at) or 0) <= self.ttl_seconds
end

function SearchResultCache:restore(key, scope)
    local entry = self.entries[key]
    if not self:_fresh(entry) then self.entries[key] = nil; return nil end
    local candidates, completed = {}, {}
    local restored = {}
    for _, identity in ipairs(entry.candidate_order or {}) do
        local item = entry.candidates and entry.candidates[identity]
        if item then
            candidates[#candidates + 1] = copy(item)
            restored[identity] = true
        end
    end
    -- Backward compatibility for entries created earlier in this process.
    for identity, item in pairs(entry.candidates or {}) do
        if not restored[identity] then candidates[#candidates + 1] = copy(item) end
    end
    for source_id, done in pairs((entry.completed or {})[scope] or {}) do if done then completed[source_id] = true end end
    entry.updated_at = now()
    return { candidates = candidates, completed = completed }
end

function SearchResultCache:record(key, scope, source_id, candidates)
    if not key or key == "" or not source_id or source_id == "" then return end
    local entry = self.entries[key]
    if not self:_fresh(entry) then
        entry = { updated_at = now(), candidates = {}, candidate_order = {}, completed = {} }
        self.entries[key] = entry
    end
    entry.candidate_order = entry.candidate_order or {}
    entry.updated_at = now()
    entry.completed[scope] = entry.completed[scope] or {}
    entry.completed[scope][tostring(source_id)] = true
    for _, candidate in ipairs(candidates or {}) do
        local item = compact(candidate)
        local identity = tostring(item.source_id or source_id) .. "\n" .. tostring(item.book_url or "")
        if tostring(scope):match("^cover:") then identity = identity .. "\n" .. tostring(item.cover or "") end
        if item.book_url and item.book_url ~= "" then
            if not entry.candidates[identity] then
                entry.candidate_order[#entry.candidate_order + 1] = identity
            end
            entry.candidates[identity] = item
        end
    end
end

function SearchResultCache:clear(key)
    if key then self.entries[key] = nil else self.entries = {} end
end

function SearchResultCache:onMemoryPressure()
    self.entries = {}
end

function SearchResultCache:onExit()
    self.entries = {}
end

return SearchResultCache
