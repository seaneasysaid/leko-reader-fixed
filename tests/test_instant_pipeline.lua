-- Count the real ReaderView input -> logic -> presentation path against a
-- supplied plugin tree.  This models the 0.15.44 direct no-animation path:
-- every tap updates the logical page and requests an ordinary rebuild, while
-- UIManager retains only the latest dirty widget before the single drain.
local plugin_root = assert(arg[1], "plugin root is required"):gsub("\\", "/")
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

package.preload["libs/libkoreader-lfs"] = function() return {} end
package.preload["util"] = function() return { splitToChars = function(value) return { value } end } end

local tap_count = math.max(1, tonumber(arg[2]) or 10)
local stats = {
    input_events = 0,
    next_page_calls = 0,
    page_constructions = 0,
    logical_page_updates = 0,
    rebuild_calls = 0,
    dirty_calls = 0,
    paint_to_calls = 0,
    screen_refresh_submissions = 0,
    refresh_types = {},
    scheduled_peak = 0,
    stale_targets_discarded = 0,
    framebuffer_peak = 0,
    disk_writes = 0,
    wait_calls = 0,
    no_merge_calls = 0,
    pagination_total_ms = 0,
    pagination_max_ms = 0,
    rebuild_total_ms = 0,
    rebuild_max_ms = 0,
    paint_total_ms = 0,
    paint_max_ms = 0,
    refresh_regions = {},
}

local function widgetModule()
    local module = {}
    function module:new(options) return options or {} end
    return module
end

for _, name in ipairs({
    "ui/widget/buttondialog",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/container/rightcontainer",
    "ui/widget/overlapgroup",
    "ui/gesturerange",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/notification",
    "ui/widget/progresswidget",
    "ui/widget/textboxwidget",
    "ui/widget/textwidget",
    "ui/widget/verticalgroup",
}) do
    package.preload[name] = widgetModule
end

local screen_bb = {
    getWidth = function() return 600 end,
    getHeight = function() return 800 end,
}
local screen = { bb = screen_bb }
function screen:refreshPartial(x, y, width, height)
    stats.screen_refresh_submissions = stats.screen_refresh_submissions + 1
    stats.refresh_regions[#stats.refresh_regions + 1] = {
        x = x, y = y, width = width, height = height,
    }
end
function screen:refreshUI() stats.screen_refresh_submissions = stats.screen_refresh_submissions + 1 end
function screen:refreshNoMergeUI() stats.no_merge_calls = stats.no_merge_calls + 1 end
function screen:refreshWaitForLast() stats.wait_calls = stats.wait_calls + 1 end
function screen:beforePaint() end
function screen:afterPaint() end

local Device = {
    screen = screen,
    isTouchDevice = function() return false end,
    hasKeys = function() return false end,
}
package.preload["device"] = function() return Device end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 1, COLOR_WHITE = 0 }
end
package.preload["ui/font"] = function() return {} end
package.preload["logger"] = function()
    return { warn = function() end, err = function() end, info = function() end }
end
package.preload["ui/geometry"] = function()
    local Geom = {}
    function Geom:new(options) return options or {} end
    return Geom
end

local scheduled = {}
local ui_manager = {}
function ui_manager:scheduleIn(_, callback)
    scheduled[#scheduled + 1] = callback
    if #scheduled > stats.scheduled_peak then stats.scheduled_peak = #scheduled end
end
function ui_manager:nextTick(callback) self:scheduleIn(0, callback) end
function ui_manager:unschedule(callback)
    for index = #scheduled, 1, -1 do
        if scheduled[index] == callback then table.remove(scheduled, index) end
    end
end
function ui_manager:setDirty(widget, refresh_type)
    stats.dirty_calls = stats.dirty_calls + 1
    self.dirty_widget = widget
    self.refresh_type = refresh_type or "ui"
end
function ui_manager:drain(reader)
    while #scheduled > 0 do
        local callback = table.remove(scheduled, 1)
        callback()
    end
    if self.dirty_widget then
        local widget = self.dirty_widget
        self.dirty_widget = nil
        local paint_started = os.clock()
        stats.paint_to_calls = stats.paint_to_calls + 1
        widget[1]:paintTo(screen.bb, 0, 0)
        local paint_ms = (os.clock() - paint_started) * 1000
        stats.paint_total_ms = stats.paint_total_ms + paint_ms
        stats.paint_max_ms = math.max(stats.paint_max_ms, paint_ms)
        stats.refresh_types[#stats.refresh_types + 1] = self.refresh_type
        if self.refresh_type == "partial" then screen:refreshPartial(0, 0, 600, 800) end
    end
end
package.preload["ui/uimanager"] = function() return ui_manager end

package.preload["ui/widget/container/inputcontainer"] = function()
    local InputContainer = {}
    function InputContainer:extend(definition)
        definition = definition or {}
        definition.__index = definition
        function definition:new(options)
            return setmetatable(options or {}, definition)
        end
        return definition
    end
    return InputContainer
end

local BookService = {}
function BookService:savePosition(book, position, flush)
    book.position = position
    if flush then stats.disk_writes = stats.disk_writes + 1 end
end
function BookService:requestPrefetch() end
function BookService:isChapterDownloaded() return true end
function BookService:loadChapterModel() return nil end
package.preload["Leko/BookService"] = function() return BookService end
package.preload["Leko/FontSelectionView"] = function() return {} end
package.preload["Leko/ReaderFooter"] = function() return {
    prefetchSignature = function() return "idle" end,
} end
package.preload["Leko/Storage"] = function()
    return {
        saveReaderStyle = function() end,
        getReaderStyle = function() return {} end,
    }
end
package.preload["Leko/TocView"] = function() return {} end
package.preload["Leko/UI"] = function() return {} end

local function positionCopy(position)
    return {
        chapter = position.chapter,
        paragraph = position.paragraph,
        char = position.char,
    }
end
package.preload["Leko/Util"] = function()
    return { positionCopy = positionCopy }
end

local function makePage(position)
    return {
        chapter_index = position.chapter,
        start_position = positionCopy(position),
        next_position = { chapter = position.chapter, paragraph = 1, char = position.char + 1 },
        at_end = false,
    }
end
local Paginator = {}
function Paginator:makePage(_, position)
    local started = os.clock()
    stats.page_constructions = stats.page_constructions + 1
    local result = makePage(position)
    local elapsed = (os.clock() - started) * 1000
    stats.pagination_total_ms = stats.pagination_total_ms + elapsed
    stats.pagination_max_ms = math.max(stats.pagination_max_ms, elapsed)
    return result
end
function Paginator:findPreviousPage(_, position)
    local started = os.clock()
    stats.page_constructions = stats.page_constructions + 1
    local result = makePage({ chapter = position.chapter, paragraph = 1, char = math.max(1, position.char - 1) })
    local elapsed = (os.clock() - started) * 1000
    stats.pagination_total_ms = stats.pagination_total_ms + elapsed
    stats.pagination_max_ms = math.max(stats.pagination_max_ms, elapsed)
    return result
end
package.preload["Leko/Paginator"] = function() return Paginator end

local ReaderView = require("Leko/ReaderView")
local original_next_page = ReaderView.nextPage
local original_previous_page = ReaderView.previousPage
local original_set_page = ReaderView.setPage
local original_rebuild = ReaderView.rebuild
ReaderView.nextPage = function(self, ...)
    stats.next_page_calls = stats.next_page_calls + 1
    return original_next_page(self, ...)
end
ReaderView.previousPage = function(self, ...)
    stats.previous_page_calls = (stats.previous_page_calls or 0) + 1
    return original_previous_page(self, ...)
end
ReaderView.setPage = function(self, ...)
    stats.logical_page_updates = stats.logical_page_updates + 1
    return original_set_page(self, ...)
end
ReaderView.rebuild = function(self, ...)
    local started = os.clock()
    stats.rebuild_calls = stats.rebuild_calls + 1
    local result = original_rebuild(self, ...)
    local elapsed = (os.clock() - started) * 1000
    stats.rebuild_total_ms = stats.rebuild_total_ms + elapsed
    stats.rebuild_max_ms = math.max(stats.rebuild_max_ms, elapsed)
    return result
end

local reader = setmetatable({
    book = { id = "pipeline", source_id = "source", chapters = { {}, {} } },
    page = makePage({ chapter = 1, paragraph = 1, char = 1 }),
    style = { show_footer = false, page_transition_enabled = false },
    history = {},
    pages_since_save = 0,
    last_progress_flush_at = os.time(),
    page_generation = 0,
    menu_visible = false,
    _closing = false,
    swipe_animation_enabled = false,
    chapter_clean_wave_enabled = false,
    dimen = { w = 1000, h = 800 },
}, ReaderView)
function reader:buildReadingPage(page)
    local rendered_page = page.start_position.char
    return {
        paintTo = function()
            self._last_painted_page = rendered_page
        end,
    }
end

local swipe = {}
function swipe:isRunning() return false end
function swipe:cancel()
    return true
end
function swipe:settle()
    return true
end
reader.swipe_refresh = swipe

local started = os.clock()
for _ = 1, tap_count do
    stats.input_events = stats.input_events + 1
    assert(reader:routeTap({ pos = { x = 999 } }))
end
local input_elapsed = os.clock() - started
ui_manager:drain(reader)
local total_elapsed = os.clock() - started

local result = {
    input_events = stats.input_events,
    next_page_calls = stats.next_page_calls,
    page_constructions = stats.page_constructions,
    logical_page_updates = stats.logical_page_updates,
    rebuild_calls = stats.rebuild_calls,
    dirty_calls = stats.dirty_calls,
    paint_to_calls = stats.paint_to_calls,
    screen_refresh_submissions = stats.screen_refresh_submissions,
    refresh_types = stats.refresh_types,
    scheduled_peak = stats.scheduled_peak,
    scheduled_remaining = #scheduled,
    stale_targets_discarded = stats.stale_targets_discarded,
    framebuffer_peak = stats.framebuffer_peak,
    disk_writes = stats.disk_writes,
    wait_calls = stats.wait_calls,
    no_merge_calls = stats.no_merge_calls,
    refresh_regions = stats.refresh_regions,
    pagination_total_ms = stats.pagination_total_ms,
    pagination_max_ms = stats.pagination_max_ms,
    rebuild_total_ms = stats.rebuild_total_ms,
    rebuild_max_ms = stats.rebuild_max_ms,
    paint_total_ms = stats.paint_total_ms,
    paint_max_ms = stats.paint_max_ms,
    history_length = #reader.history,
    final_page = reader.page.start_position.char,
    final_painted_page = reader._last_painted_page,
    input_elapsed_ms = input_elapsed * 1000,
    total_elapsed_ms = total_elapsed * 1000,
}
local transition_source_file = io.open(plugin_root .. "/Leko/SwipeRefresh.lua", "rb")
local transition_source = transition_source_file and transition_source_file:read("*a") or ""
if transition_source_file then transition_source_file:close() end
assert(not transition_source:find("function SwipeRefresh:requestInstant", 1, true),
    "direct no-animation pipeline still contains requestInstant")
local strict = arg[3] ~= "report"
if strict then assert(result.input_events == tap_count and result.next_page_calls == tap_count
    and result.logical_page_updates == tap_count
    and result.page_constructions == tap_count
    and result.final_page == tap_count + 1
    and result.final_painted_page == result.final_page
    and result.history_length == tap_count
    and result.screen_refresh_submissions == 1
    and result.paint_to_calls == 1
    and result.wait_calls == 0
    and result.no_merge_calls == 0
    and result.disk_writes == 0
    and result.scheduled_remaining == 0,
    "input, logic and final visual state did not converge") end
if strict then
    assert(result.rebuild_calls == tap_count
        and result.dirty_calls == tap_count
        and result.scheduled_peak == 0
        and result.stale_targets_discarded == 0,
        "0.15.44 direct no-animation path changed unexpectedly")
end
local function jsonString(value)
    return string.format("%q", value)
end
local function jsonValue(value)
    if type(value) == "string" then return jsonString(value) end
    if type(value) == "number" then return tostring(value) end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "table" then
        local items = {}
        local is_array = (#value > 0)
        if is_array then
            for index = 1, #value do items[#items + 1] = jsonValue(value[index]) end
            return "[" .. table.concat(items, ",") .. "]"
        end
        for key, item in pairs(value) do
            items[#items + 1] = jsonString(key) .. ":" .. jsonValue(item)
        end
        table.sort(items)
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end
print(jsonValue(result))
