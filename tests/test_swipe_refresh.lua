local root = (arg[1] or "."):gsub("\\", "/")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local scheduled = {}
local events = {}
local freed = {}
local next_buffer_id = 0

local screen_bb = {}
function screen_bb:getWidth() return 80 end
function screen_bb:getHeight() return 100 end
function screen_bb:getType() return "gray8" end
function screen_bb:getRotation() return 1 end
function screen_bb:blitFrom(source, dx, dy, sx, sy, width, height)
    events[#events + 1] = {
        kind = "blit",
        source = source.id,
        x = dx,
        y = dy,
        sx = sx,
        sy = sy,
        width = width,
        height = height,
    }
end
function screen_bb:paintRect(x, y, width, height, color)
    events[#events + 1] = {
        kind = "paint",
        x = x,
        y = y,
        width = width,
        height = height,
        color = color,
    }
end

local blitbuffer = {
    COLOR_WHITE = 0,
    COLOR_BLACK = 1,
}
function blitbuffer.new(width, height, bb_type)
    next_buffer_id = next_buffer_id + 1
    local buffer = { id = next_buffer_id, width = width, height = height, bb_type = bb_type }
    function buffer:fill() self.filled = true end
    function buffer:setRotation(rotation) self.rotation = rotation end
    function buffer:free() freed[self.id] = (freed[self.id] or 0) + 1 end
    return buffer
end

local screen = { bb = screen_bb }
function screen:beforePaint() events[#events + 1] = { kind = "before" } end
function screen:afterPaint() events[#events + 1] = { kind = "after" } end
function screen:setSwipeDirection(left) events[#events + 1] = { kind = "direction", left = left } end
function screen:setSwipeAnimations(enabled)
    events[#events + 1] = { kind = "native", enabled = enabled }
end
function screen:refreshUI(x, y, width, height)
    events[#events + 1] = { kind = "refresh", x = x, y = y, width = width, height = height }
end
function screen:refreshNoMergeUI(x, y, width, height)
    events[#events + 1] = { kind = "no_merge", x = x, y = y, width = width, height = height }
end
function screen:refreshFast(x, y, width, height)
    events[#events + 1] = { kind = "fast", x = x, y = y, width = width, height = height }
end
function screen:refreshWaitForLast() events[#events + 1] = { kind = "wait" } end

local ui_manager = {}
function ui_manager:scheduleIn(_, callback) scheduled[#scheduled + 1] = callback end
function ui_manager:unschedule(callback)
    for index = #scheduled, 1, -1 do
        if scheduled[index] == callback then table.remove(scheduled, index) end
    end
end

local mtk_device = {
    screen = screen,
    canDoSwipeAnimation = function() return true end,
}
local legacy_device = {
    screen = screen,
    canDoSwipeAnimation = function() return false end,
}

package.loaded["ffi/blitbuffer"] = blitbuffer
package.loaded["device"] = mtk_device
package.loaded["Leko/SwipeRefresh"] = nil
package.loaded["Leko/SwipeAnimation"] = nil
package.loaded["Leko/ChapterWaveRefresh"] = nil

local SwipeRefresh = require("Leko/SwipeRefresh")

local function widget(id)
    return {
        paintTo = function(_, target)
            target.rendered_from = id
        end,
    }
end

local function drainCallbacks()
    while #scheduled > 0 do
        assert(#scheduled == 1, "transition created a callback backlog")
        local callback = table.remove(scheduled, 1)
        callback()
    end
end

-- MTK: one full UI submission, with semantic direction mapped to the native
-- left/right boolean. There is no software strip loop.
local transition = SwipeRefresh:new{
    screen = screen,
    ui_manager = ui_manager,
    device = mtk_device,
}
local completed = 0
assert(transition:begin(widget("A"), SwipeRefresh.FORWARD, function() completed = completed + 1 end, {
    chapter_changed = false,
    page_animation_enabled = true,
}))
assert(transition:isRunning() and #scheduled == 1, "native swipe must have one completion callback")
assert(transition.target_framebuffer.rotation == 1, "target must inherit Screen.bb rotation")
local stale_native_callback = scheduled[1]
assert(events[3].kind == "direction" and events[3].left == true,
    "forward page must map to native left swipe")
assert(events[4].kind == "native" and events[4].enabled == true,
    "native swipe flag was not set immediately before refresh")
assert(events[5].kind == "refresh" and events[5].width == 80,
    "native swipe must submit the complete reader surface")

assert(transition:begin(widget("B"), SwipeRefresh.BACKWARD, function() completed = completed + 1 end, {
    chapter_changed = false,
    page_animation_enabled = true,
}))
stale_native_callback()
assert(transition:isRunning() and completed == 0, "stale native callback changed the latest target")
drainCallbacks()
assert(not transition:isRunning() and completed == 1, "latest native target did not complete exactly once")
assert(freed[1] == 1, "replaced native target was not released exactly once")

-- A chapter boundary prefers the cleanup wave only when it is enabled. With
-- the wave disabled, the same native swipe backend remains available.
events = {}
assert(transition:begin(widget("cross-fallback"), SwipeRefresh.FORWARD, nil, {
    chapter_changed = true,
    page_animation_enabled = true,
    chapter_clean_wave_enabled = false,
}))
assert(transition:isRunning() and #scheduled == 1,
    "cross-chapter page must fall back to ordinary native swipe when wave is off")
drainCallbacks()
local cross_native = false
for _, event in ipairs(events) do
    if event.kind == "native" and event.enabled == true then cross_native = true end
end
assert(cross_native, "cross-chapter fallback did not use native swipe")

-- Legacy: same-chapter animation uses the .40/.42-style local UI strip
-- fallback. It keeps one callback only and reveals the target in semantic
-- direction order when native hardware swipe is unavailable.
local legacy = SwipeRefresh:new{
    screen = screen,
    ui_manager = ui_manager,
    device = legacy_device,
}
events = {}
local same_completed = 0
local legacy_started = legacy:begin(widget("same"), SwipeRefresh.FORWARD, function()
    same_completed = same_completed + 1
end, {
    chapter_changed = false,
    page_animation_enabled = true,
})
assert(legacy_started and legacy:isRunning() and #scheduled == 1,
    "legacy same-chapter page must start one software strip callback")
drainCallbacks()
assert(not legacy:isRunning() and same_completed == 1,
    "legacy software swipe did not complete exactly once")
local same_refresh, same_native = false, false
for _, event in ipairs(events) do
    if event.kind == "refresh" then same_refresh = true end
    if event.kind == "native" or event.kind == "direction" then same_native = true end
end
assert(same_refresh and not same_native,
    "legacy software swipe must use UI strips without native flags")

-- A newer request replaces the old strip transition immediately. The stale
-- callback must be harmless and must not create a second pending callback.
events = {}
local replacement_completed = 0
assert(legacy:begin(widget("same-A"), SwipeRefresh.FORWARD, nil, {
    chapter_changed = false,
    page_animation_enabled = true,
}))
local stale_software_callback = scheduled[1]
assert(legacy:begin(widget("same-B"), SwipeRefresh.BACKWARD, function()
    replacement_completed = replacement_completed + 1
end, {
    chapter_changed = false,
    page_animation_enabled = true,
}))
assert(#scheduled == 1, "replaced software swipe created a callback backlog")
stale_software_callback()
assert(legacy:isRunning() and replacement_completed == 0,
    "stale software callback changed the latest target")
drainCallbacks()
assert(not legacy:isRunning() and replacement_completed == 1,
    "latest software target did not complete exactly once")

-- A runtime toggle/cancel must release the one target and unschedule the one
-- callback without waiting for the display waveform. A callback that was
-- already handed to the host must still be harmless after cancellation.
local cancel_target_id
assert(legacy:begin(widget("toggle-off"), SwipeRefresh.FORWARD, nil, {
    chapter_changed = false,
    page_animation_enabled = true,
}))
cancel_target_id = legacy.target_framebuffer.id
local stale_cancel_callback = scheduled[1]
assert(legacy:cancel() and not legacy:isRunning() and #scheduled == 0,
    "runtime animation cancel left a callback or running state")
stale_cancel_callback()
assert(freed[cancel_target_id] == 1,
    "runtime animation cancel did not release the target exactly once")

-- When page animation is disabled, begin() is a no-op contract: it must not
-- render a target, schedule a callback or touch a refresh/wait API.
events = {}
local disabled = legacy:begin(widget("disabled"), SwipeRefresh.FORWARD, nil, {
    chapter_changed = true,
    page_animation_enabled = false,
    chapter_clean_wave_enabled = true,
})
assert(not disabled and not legacy:isRunning() and #scheduled == 0,
    "disabled animation must not start SwipeRefresh")
assert(#events == 0, "disabled animation touched the Screen")
local disabled_same = legacy:begin(widget("disabled-same"), SwipeRefresh.FORWARD, nil, {
    chapter_changed = false,
    page_animation_enabled = false,
    chapter_clean_wave_enabled = false,
})
assert(not disabled_same and #scheduled == 0 and #events == 0,
    "same-chapter disabled animation must also be a no-op")

-- Legacy chapter boundary: the wave performs black, white and target-region
-- UI submissions one scheduled step at a time, without waiting for physical
-- completion after each frame or at the end.
events = {}
local wave_completed = 0
assert(legacy:begin(widget("chapter-B"), SwipeRefresh.FORWARD, function() wave_completed = wave_completed + 1 end, {
    chapter_changed = true,
    page_animation_enabled = true,
    chapter_clean_wave_enabled = true,
}))
assert(legacy:isRunning() and #scheduled == 1, "chapter wave must start with one pending frame")
local stale_wave_callback = scheduled[1]
assert(legacy:begin(widget("chapter-C"), SwipeRefresh.BACKWARD, function() wave_completed = wave_completed + 1 end, {
    chapter_changed = true,
    chapter_clean_wave_enabled = true,
}))
stale_wave_callback()
assert(legacy:isRunning() and wave_completed == 0, "stale chapter wave callback changed the latest target")
drainCallbacks()
assert(not legacy:isRunning() and wave_completed == 1, "chapter wave did not complete exactly once")

local has_black, has_white, has_target_blit = false, false, false
local wait_count, refresh_count, no_merge_count, fast_count = 0, 0, 0, 0
for _, event in ipairs(events) do
    if event.kind == "paint" and event.color == blitbuffer.COLOR_BLACK then has_black = true end
    if event.kind == "paint" and event.color == blitbuffer.COLOR_WHITE then has_white = true end
    if event.kind == "blit" then has_target_blit = true end
    if event.kind == "wait" then wait_count = wait_count + 1 end
    if event.kind == "refresh" then refresh_count = refresh_count + 1 end
    if event.kind == "no_merge" then no_merge_count = no_merge_count + 1 end
    if event.kind == "fast" then fast_count = fast_count + 1 end
    assert(event.kind ~= "native", "legacy chapter wave must not use MTK native swipe")
end
assert(has_black and has_white and has_target_blit,
    "chapter wave must submit black, white and target states")
assert(wait_count == 0, "chapter wave must not wait for physical completion")
assert(refresh_count <= 10, "chapter wave used too many driver submissions")
assert(no_merge_count > 0, "chapter wave did not use its scoped no-merge submissions")
assert(fast_count == 0, "chapter wave unexpectedly used fast submissions")

-- Turning off the wave falls back to ordinary software swipe on this legacy
-- device; it does not silently remove the page animation.
events = {}
local wave_disabled = legacy:begin(widget("chapter-D"), SwipeRefresh.FORWARD, nil, {
    chapter_changed = true,
    page_animation_enabled = true,
    chapter_clean_wave_enabled = false,
})
assert(wave_disabled and legacy:isRunning() and #scheduled == 1,
    "disabled chapter wave must fall back to software swipe")
drainCallbacks()

-- A backend without paint support cannot run the cleanup wave, but it still
-- retains ordinary software swipe as the chapter fallback.
local no_wave_bb = {
    getWidth = function() return 80 end,
    getHeight = function() return 100 end,
    getType = function() return "gray8" end,
    getRotation = function() return 1 end,
    blitFrom = function(_, source, dx, dy, sx, sy, width, height)
        events[#events + 1] = { kind = "blit", source = source.id, x = dx, y = dy,
            sx = sx, sy = sy, width = width, height = height }
    end,
}
local no_wave_screen = {
    bb = no_wave_bb,
    beforePaint = screen.beforePaint,
    afterPaint = screen.afterPaint,
    refreshUI = screen.refreshUI,
}
local no_wave_device = {
    screen = no_wave_screen,
    canDoSwipeAnimation = function() return false end,
}
local no_wave_transition = SwipeRefresh:new{
    screen = no_wave_screen,
    ui_manager = ui_manager,
    device = no_wave_device,
}
events = {}
assert(no_wave_transition:begin(widget("chapter-E"), SwipeRefresh.FORWARD, nil, {
    chapter_changed = true,
    page_animation_enabled = true,
    chapter_clean_wave_enabled = true,
}))
assert(no_wave_transition:isRunning() and #scheduled == 1,
    "unavailable chapter wave must use software swipe")
drainCallbacks()

-- settle() is the explicit UI-boundary path and commits the latest target once
-- without waiting for physical waveform completion.
local settled = 0
events = {}
assert(legacy:begin(widget("chapter-F"), SwipeRefresh.FORWARD, function() settled = settled + 1 end, {
    chapter_changed = true,
    chapter_clean_wave_enabled = true,
}))
local first_wave_frame = table.remove(scheduled, 1)
first_wave_frame()
assert(legacy:settle() and not legacy:isRunning(), "settle did not stop the chapter wave")
assert(settled == 1, "settle must complete the latest target exactly once")
local settle_waits = 0
for _, event in ipairs(events) do if event.kind == "wait" then settle_waits = settle_waits + 1 end end
assert(settle_waits == 0, "settle must not wait for physical waveform completion")

-- Twenty same-chapter requests must keep replacing one software animation,
-- with one pending callback and no physical waits.
events = {}
local twenty_completed = 0
for index = 1, 20 do
    assert(legacy:begin(widget("rapid-" .. index), SwipeRefresh.FORWARD, function()
        twenty_completed = twenty_completed + 1
    end, {
        chapter_changed = false,
        page_animation_enabled = true,
    }))
    assert(#scheduled == 1, "rapid software turns accumulated callbacks")
end
drainCallbacks()
assert(not legacy:isRunning() and twenty_completed == 1,
    "rapid turns did not converge to the latest software target")
for _, event in ipairs(events) do
    assert(event.kind ~= "wait", "rapid turns synchronously waited for the driver")
end

print("Leko animation matrix, fallbacks, rapid replacement and nonblocking settle contracts: OK")
