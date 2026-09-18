-- Document-less Leko reader bridge for KOReader's native statistics.sqlite3.
-- It intentionally talks only to the public database schema: no ReaderUI,
-- Document or CREngine stand-in is constructed here.
local DataStorage = require("datastorage")
local Digest = require("Leko/Digest")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Bridge = {}
Bridge.__index = Bridge

local SCHEMA_VERSION = 20221111
local VIRTUAL_PAGE_COUNT = 10000
local MIN_SECONDS, MAX_SECONDS = 5, 120
local FLUSH_TURNS = 50

local function close(statement)
    if statement and type(statement.close) == "function" then pcall(statement.close, statement) end
end

local Store = {}
Store.__index = Store

function Store:new(options)
    options = options or {}
    return setmetatable({
        db_path = options.db_path or (DataStorage:getSettingsDir() .. "/statistics.sqlite3"),
        open = options.open_db or SQ3.open,
        exists = options.file_exists or function(path) return lfs.attributes(path, "mode") == "file" end,
    }, self)
end

function Store:_open()
    if not self.exists(self.db_path) then return nil, "KOReader Statistics database does not exist" end
    local ok, db = pcall(self.open, self.db_path)
    if not ok or not db then return nil, tostring(db or "cannot open statistics database") end
    local version = tonumber(db:rowexec("PRAGMA user_version;"))
    local book = db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='book';")
    local data = db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='page_stat_data';")
    local view = db:rowexec("SELECT name FROM sqlite_master WHERE type='view' AND name='page_stat';")
    if version ~= SCHEMA_VERSION or not book or not data or not view then
        db:close()
        return nil, "unsupported KOReader Statistics schema: " .. tostring(version)
    end
    return db
end

function Store:getOrCreate(book, md5, pages, now)
    local db, err = self:_open()
    if not db then return nil, err end
    local statement
    local ok, result = xpcall(function()
        statement = db:prepare("SELECT id FROM book WHERE md5 = ? ORDER BY id LIMIT 1;")
        local row = statement:reset():bind(md5):step()
        local id = row and tonumber(row[1])
        close(statement); statement = nil
        if id then return id end
        db:exec("BEGIN IMMEDIATE;")
        statement = db:prepare([[INSERT INTO book
            (title, authors, notes, last_open, highlights, pages, series, language, md5, total_read_time, total_read_pages)
            VALUES (?, ?, 0, ?, 0, ?, 'N/A', 'N/A', ?, 0, 0);]])
        statement:reset():bind(tostring(book.title or "未命名"), tostring(book.author or "N/A"), now, pages, md5):step()
        close(statement); statement = nil
        id = tonumber(db:rowexec("SELECT last_insert_rowid();"))
        db:exec("COMMIT;")
        return id
    end, debug and debug.traceback or tostring)
    close(statement)
    if not ok then pcall(db.exec, db, "ROLLBACK;") end
    db:close()
    return ok and result or nil, ok and nil or tostring(result)
end

function Store:write(id, periods, pages, now)
    if not id or #periods == 0 then return true end
    local db, err = self:_open()
    if not db then return nil, err end
    local statement
    local ok, result = xpcall(function()
        db:exec("BEGIN IMMEDIATE;")
        statement = db:prepare([[INSERT OR IGNORE INTO page_stat_data
            (id_book, page, start_time, duration, total_pages) VALUES (?, ?, ?, ?, ?);]])
        for _, period in ipairs(periods) do
            statement:reset():bind(id, period.page, period.start_time, period.duration, period.total_pages or pages):step()
        end
        close(statement); statement = nil
        local count, seconds = db:rowexec(string.format("SELECT count(DISTINCT page), sum(duration) FROM page_stat WHERE id_book = %d;", id))
        statement = db:prepare("UPDATE book SET pages=?, last_open=?, total_read_time=?, total_read_pages=? WHERE id=?;")
        statement:reset():bind(pages, now, tonumber(seconds) or 0, tonumber(count) or 0, id):step()
        close(statement); statement = nil
        db:exec("COMMIT;")
        return true
    end, debug and debug.traceback or tostring)
    close(statement)
    if not ok then pcall(db.exec, db, "ROLLBACK;") end
    db:close()
    return ok and result or nil, ok and nil or tostring(result)
end

local function settings()
    local default = { is_enabled = true, min_sec = MIN_SECONDS, max_sec = MAX_SECONDS }
    if not G_reader_settings or type(G_reader_settings.readSetting) ~= "function" then return default end
    local value = G_reader_settings:readSetting("statistics", default) or default
    return {
        is_enabled = value.is_enabled ~= false,
        min_sec = tonumber(value.min_sec) or MIN_SECONDS,
        max_sec = tonumber(value.max_sec) or MAX_SECONDS,
    }
end

function Bridge:new(options)
    options = options or {}
    local configured = options.settings or settings()
    return setmetatable({
        clock = options.clock or os.time, store = options.store or Store:new(options),
        enabled = configured.is_enabled ~= false,
        min_sec = math.max(0, tonumber(configured.min_sec) or MIN_SECONDS),
        max_sec = math.max(1, tonumber(configured.max_sec) or MAX_SECONDS),
        total_pages = VIRTUAL_PAGE_COUNT, periods = {}, active = false,
    }, self)
end

function Bridge:identityForBook(book)
    return Digest:md5("leko-reader\0" .. tostring(book and book.id or ""))
end

function Bridge:start(book, page)
    if self.closed or not self.enabled or type(book) ~= "table" or not book.id then return false end
    local now = self.clock()
    local id, err = self.store:getOrCreate(book, self:identityForBook(book), self.total_pages, now)
    if not id then logger.warn("Leko Statistics bridge unavailable:", err); return false end
    self.book_id, self.statistics_id = tostring(book.id), tonumber(id)
    self.current_page = math.max(1, math.min(self.total_pages, tonumber(page) or 1))
    self.period_start, self.period_origin, self.period_elapsed = now, now, 0
    self.active = true
    return true
end

function Bridge:_finish(now)
    if not self.active or not self.period_origin then return end
    local elapsed = tonumber(self.period_elapsed) or 0
    if not self.paused and self.period_start then elapsed = elapsed + math.max(0, now - self.period_start) end
    if elapsed >= self.min_sec then
        self.periods[#self.periods + 1] = { page = self.current_page, start_time = self.period_origin,
            duration = math.min(elapsed, self.max_sec), total_pages = self.total_pages }
    end
    self.period_start, self.period_origin, self.period_elapsed = nil, nil, 0
end

function Bridge:flush()
    if not self.statistics_id or #self.periods == 0 then return true end
    local pending = self.periods
    local ok, err = self.store:write(self.statistics_id, pending, self.total_pages, self.clock())
    if ok then self.periods, self.turns = {}, 0; return true end
    logger.warn("Leko Statistics flush failed:", err)
    return nil, err
end

function Bridge:checkpoint()
    if not self.active or self.paused then return self:flush() end
    local now = self.clock(); self:_finish(now)
    self.period_start, self.period_origin = now, now
    return self:flush()
end

function Bridge:onPageChanged(page)
    if not self.active or self.paused then return false end
    local now = self.clock(); self:_finish(now)
    self.current_page = math.max(1, math.min(self.total_pages, tonumber(page) or self.current_page or 1))
    self.period_start, self.period_origin = now, now
    self.turns = (self.turns or 0) + 1
    if self.turns >= FLUSH_TURNS then self:flush() end
    return true
end

function Bridge:pause()
    if not self.active or self.paused then return true end
    local now = self.clock()
    if self.period_start then self.period_elapsed = (self.period_elapsed or 0) + math.max(0, now - self.period_start) end
    self.period_start, self.paused_at, self.paused = nil, now, true
    return self:flush()
end

function Bridge:resume(page)
    if not self.active or not self.paused then return true end
    local now = self.clock()
    self.current_page = math.max(1, math.min(self.total_pages, tonumber(page) or self.current_page or 1))
    if self.period_origin and self.paused_at then self.period_origin = self.period_origin + math.max(0, now - self.paused_at) end
    self.period_start, self.period_origin, self.paused_at, self.paused = now, self.period_origin or now, nil, false
    return true
end

function Bridge:close()
    if self.closed then return true end
    if self.active then self:_finish(self.clock()) end
    self:flush()
    self.active, self.paused, self.closed = false, false, true
    return true
end

Bridge.DB_SCHEMA_VERSION = SCHEMA_VERSION
Bridge.VIRTUAL_PAGE_COUNT = VIRTUAL_PAGE_COUNT
Bridge.NativeStore = Store

return Bridge
