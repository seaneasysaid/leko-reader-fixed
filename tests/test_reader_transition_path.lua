local plugin_root = assert(arg[1], "plugin root is required"):gsub("\\", "/")
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

-- Keep this test on ReaderView:setPage's real dispatch path while replacing
-- only KOReader widgets and unrelated reader services with small doubles.
package.preload["libs/libkoreader-lfs"] = function() return {} end
package.preload["util"] = function()
    return { splitToChars = function(value) return { value } end }
end

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
    "ui/widget/overlapgroup",
    "ui/widget/container/rightcontainer",
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

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 1, COLOR_WHITE = 0 }
end
package.preload["device"] = function()
    return { screen = {}, isTouchDevice = function() return false end,
        hasKeys = function() return false end }
end
local ui_manager = {
    setDirty = function(_, owner)
        owner.rebuild_calls = (owner.rebuild_calls or 0) + 1
    end,
}
package.preload["ui/uimanager"] = function() return ui_manager end
package.preload["ui/font"] = function() return {} end
package.preload["logger"] = function()
    return { warn = function() end, err = function() end, info = function() end }
end
package.preload["ui/geometry"] = function()
    local Geom = {}
    function Geom:new(options) return options or {} end
    return Geom
end
package.preload["ui/widget/container/inputcontainer"] = function()
    local InputContainer = {}
    function InputContainer:extend(definition)
        definition = definition or {}
        definition.__index = definition
        function definition:new(options)
            local instance = setmetatable(options or {}, definition)
            if instance.init then instance:init() end
            return instance
        end
        return definition
    end
    return InputContainer
end

local BookService = {
    save_calls = 0,
    prefetch_calls = 0,
}
function BookService:savePosition(book, position)
    self.save_calls = self.save_calls + 1
    book.position = position
end
function BookService:requestPrefetch()
    self.prefetch_calls = self.prefetch_calls + 1
end
package.preload["Leko/BookService"] = function() return BookService end
package.preload["Leko/FontSelectionView"] = function() return {} end
package.preload["Leko/Paginator"] = function() return {} end
package.preload["Leko/Storage"] = function()
    return {
        saveReaderStyle = function() end,
        getReaderStyle = function() return {} end,
    }
end
package.preload["Leko/TocView"] = function() return {} end
package.preload["Leko/UI"] = function() return {} end
package.preload["Leko/ReaderFooter"] = function() return {} end

local ReaderView = require("Leko/ReaderView")

local function page(chapter, char)
    return {
        chapter_index = chapter,
        chapter_title = "测试",
        start_position = { chapter = chapter, paragraph = 1, char = char or 1 },
        next_position = { chapter = chapter, paragraph = 1, char = (char or 1) + 10 },
        geometry = {},
        elements = {},
        at_end = false,
    }
end

local function reader(animation_enabled, wave_enabled, running, show_footer, begin_result)
    local fake_swipe = {
        begin_calls = 0,
        cancel_calls = 0,
        is_running_calls = 0,
        running = running == true,
        begin_result = begin_result,
        last_options = nil,
    }
    function fake_swipe:isRunning()
        self.is_running_calls = self.is_running_calls + 1
        return self.running
    end
    function fake_swipe:begin(_, _, _, options)
        self.begin_calls = self.begin_calls + 1
        self.last_options = options
        if self.begin_result == false then return nil, "backend failure" end
        return true
    end
    function fake_swipe:cancel()
        self.cancel_calls = self.cancel_calls + 1
        self.running = false
        return true
    end

    local instance = setmetatable({
        book = { id = "reader-path", chapters = { {}, {} } },
        page = page(1, 1),
        style = { show_footer = show_footer ~= false },
        history = {},
        pages_since_save = 0,
        last_progress_flush_at = os.time(),
        page_generation = 1,
        menu_visible = false,
        _closing = false,
        swipe_animation_enabled = animation_enabled,
        chapter_clean_wave_enabled = wave_enabled,
        swipe_refresh = fake_swipe,
        dimen = {},
        rebuild_calls = 0,
    }, ReaderView)
    function instance:buildReadingPage() return { target = true } end
    return instance, fake_swipe
end

-- Both animation switches off: ReaderView must update the page through the
-- ordinary rebuild path and must never enter SwipeRefresh:begin().
local no_animation, no_animation_swipe = reader(false, false, false)
assert(no_animation:setPage(page(2, 1), "partial", "forward", 1))
assert(no_animation_swipe.begin_calls == 0 and no_animation.rebuild_calls == 1,
    "no-animation page turn did not use the direct rebuild path")
local no_animation_same, no_animation_same_swipe = reader(false, false, false)
assert(no_animation_same:setPage(page(1, 2), "partial", "forward", 1))
assert(no_animation_same_swipe.begin_calls == 0 and no_animation_same.rebuild_calls == 1,
    "same-chapter no-animation page turn did not use direct rebuild")
local no_footer, no_footer_swipe = reader(false, false, false, false)
assert(no_footer:setPage(page(1, 2), "partial", "forward", 1))
assert(no_footer_swipe.begin_calls == 0 and no_footer.rebuild_calls == 1,
    "hidden footer changed the direct page dispatch")

-- Even if a stale coordinator flag is present when the setting is toggled,
-- the disabled path must not consult or wait on it: it must behave like the
-- 0.15.39 direct rebuild path.
local stale_disabled, stale_disabled_swipe = reader(false, false, true)
assert(stale_disabled:setPage(page(1, 2), "partial", "forward", 1))
assert(stale_disabled_swipe.begin_calls == 0
    and stale_disabled_swipe.cancel_calls == 0
    and stale_disabled_swipe.is_running_calls == 0
    and stale_disabled.rebuild_calls == 1,
    "disabled page turn was still gated by stale transition state")

-- Exercise the public nextPage path repeatedly, rather than only calling
-- setPage directly. A downloaded same-chapter turn must never enter a wait,
-- queue or coordinator check when both animation switches are off.
local rapid_no_animation, rapid_no_animation_swipe = reader(false, false, false)
function rapid_no_animation:loadPage(position, refresh_type, direction, generation)
    return self:setPage(page(position.chapter, position.char), refresh_type,
        direction, generation)
end
for index = 1, 20 do
    assert(rapid_no_animation:nextPage(), "ordinary rapid page turn was rejected")
end
assert(rapid_no_animation_swipe.begin_calls == 0
    and rapid_no_animation_swipe.is_running_calls == 0
    and rapid_no_animation.rebuild_calls == 20,
    "ordinary rapid page turns did not use direct rebuilds")

-- Forward/backward history is a logical command stream independent of the
-- single pending visual presentation. Twenty forward turns followed by
-- twenty history turns must return to the exact starting position.
local history_reader, history_swipe = reader(false, false, false)
function history_reader:loadPage(position, refresh_type, direction, generation)
    return self:setPage(page(position.chapter, position.char), refresh_type,
        direction, generation)
end
for _ = 1, 20 do assert(history_reader:nextPage()) end
assert(history_reader.page.start_position.char == 201 and #history_reader.history == 20,
    "forward command history did not retain all twenty turns")
for _ = 1, 20 do assert(history_reader:previousPage()) end
assert(history_reader.page.start_position.char == 1 and #history_reader.history == 0,
    "backward history did not return to the starting page")
assert(history_reader.rebuild_calls == 40,
    "backward history did not use the direct rebuild path")

-- Mixed forward/backward input must preserve the same semantics: the page
-- position and history are updated per command, while every no-animation turn
-- uses the ordinary direct rebuild path.
local mixed_reader, mixed_swipe = reader(false, false, false)
function mixed_reader:loadPage(position, refresh_type, direction, generation)
    return self:setPage(page(position.chapter, position.char), refresh_type,
        direction, generation)
end
for _ = 1, 10 do assert(mixed_reader:nextPage()) end
for _ = 1, 3 do assert(mixed_reader:previousPage()) end
for _ = 1, 5 do assert(mixed_reader:nextPage()) end
assert(mixed_reader.page.start_position.char == 121 and #mixed_reader.history == 12,
    "mixed forward/backward commands changed the logical history")
assert(mixed_reader.rebuild_calls == 18,
    "mixed input did not use the direct rebuild path")

-- A transition backend failure is not allowed to drop the page request. The
-- same ReaderView path must fall back to one ordinary direct rebuild.
local failed_backend, failed_swipe = reader(true, false, false, true, false)
assert(failed_backend:setPage(page(1, 2), "partial", "forward", 1))
assert(failed_swipe.begin_calls == 1 and failed_backend.rebuild_calls == 1,
    "transition backend failure did not fall back to direct rebuild")

-- Animation on, wave off at a chapter boundary: the coordinator receives the
-- request and is responsible for native/software ordinary swipe fallback.
local ordinary_cross, ordinary_swipe = reader(true, false, false)
assert(ordinary_cross:setPage(page(2, 1), "partial", "forward", 1))
assert(ordinary_swipe.begin_calls == 1
    and ordinary_swipe.last_options.chapter_changed == true
    and ordinary_swipe.last_options.chapter_clean_wave_enabled == false,
    "cross-chapter wave-off path did not enter ordinary swipe")

-- Animation on, wave on at a chapter boundary: the same real path passes the
-- wave preference to the coordinator.
local wave_cross, wave_swipe = reader(true, true, false)
assert(wave_cross:setPage(page(2, 1), "partial", "forward", 1))
assert(wave_swipe.begin_calls == 1
    and wave_swipe.last_options.chapter_changed == true
    and wave_swipe.last_options.chapter_clean_wave_enabled == true,
    "cross-chapter wave-on path did not enter the coordinator")

-- Toggling animation off while a transition is running cancels without settle
-- or a physical wait, then performs one ordinary rebuild.
local toggled, toggled_swipe = reader(true, true, true)
assert(toggled:setSwipeAnimationEnabled(false) == false)
assert(toggled_swipe.cancel_calls == 1 and toggled.rebuild_calls == 1,
    "turning animation off did not cancel and rebuild directly")

print("ReaderView real page-dispatch path bypasses animation when disabled: OK")
