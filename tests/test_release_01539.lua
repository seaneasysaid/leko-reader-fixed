local plugin_root = assert(arg[1], "plugin root is required")
plugin_root = plugin_root:gsub("\\", "/")
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "assertion failed") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local syntax_files = {
    "Leko/AsyncBookOperation.lua",
    "Leko/BookExporter.lua",
    "Leko/BookMutationCoordinator.lua",
    "Leko/FontSelectionView.lua",
    "Leko/ImagePipeline.lua",
    "Leko/Paginator.lua",
    "Leko/ReaderView.lua",
    "Leko/Regex.lua",
    "Leko/Storage.lua",
}
for _, relative in ipairs(syntax_files) do
    local chunk, err = loadfile(plugin_root .. "/" .. relative)
    if not chunk then error("Lua syntax failed for " .. relative .. ": " .. tostring(err), 2) end
end

-- Exercise the native PCRE replacement path. The project runtime is Lua 5.3,
-- so this is a small FFI-shaped PCRE double, not a second test runtime.
local fake_pcre = {}
function fake_pcre.pcre_compile() return {} end
function fake_pcre.pcre_free() end
function fake_pcre.pcre_exec(_, _, subject, _, start_offset, _, ovec)
    local start_pos, end_pos = tostring(subject):find("ab", (start_offset or 0) + 1, true)
    if not start_pos then return -1 end
    ovec[0], ovec[1] = start_pos - 1, end_pos
    ovec[2], ovec[3] = start_pos - 1, start_pos
    ovec[4], ovec[5] = start_pos, end_pos
    return 3
end
local fake_ffi = {
    cdef = function() end,
    load = function() return fake_pcre end,
    string = function(value) return tostring(value) end,
}
function fake_ffi.new(type_name, size)
    local result = {}
    local count = tonumber(size) or tonumber(tostring(type_name):match("%[(%d+)%]")) or 1
    for index = 0, count - 1 do result[index] = 0 end
    return result
end
package.preload["ffi"] = function() return fake_ffi end
package.loaded["Leko/Regex"] = nil
local Regex = require("Leko/Regex")
assertEqual(Regex:isNative(), true, "native PCRE path was not selected")
assertEqual(Regex:replace("ab ab", "(a)(b)", "<$1>${2}\\1$$", "g"), "<a>ba$ <a>ba$",
    "native replacement expansion")
assertEqual(Regex:replace("ab", "(a)(b)", "", "g"), "", "empty native replacement")

-- The persisted style shape is intentionally checked as source, because the
-- real settings object belongs to KOReader's device runtime.
local function readSource(relative)
    local file = assert(io.open(plugin_root .. "/" .. relative, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end
local storage_source = readSource("Leko/Storage.lua")
assert(storage_source:find("body_font_index", 1, true), "body font face index is not persisted")
assert(storage_source:find("title_font_index", 1, true), "title font face index is not persisted")
assert(storage_source:find("body_font_display_name", 1, true), "font display name is not persisted")
local paginator_source = readSource("Leko/Paginator.lua")
local reader_source = readSource("Leko/ReaderView.lua")
local swipe_source = readSource("Leko/SwipeRefresh.lua")
local wave_source = readSource("Leko/ChapterWaveRefresh.lua")
local native_source = readSource("Leko/SwipeAnimation.lua")
local footer_source = readSource("Leko/ReaderFooter.lua")
local version_source = readSource("Leko/Version.lua")
local install_source = readSource("INSTALL.txt")
assert(paginator_source:find('lang = "zh-CN"', 1, true), "CJK measurement language is not pinned")
assert(reader_source:find('lang = "zh-CN"', 1, true), "CJK drawing language is not pinned")
assert(reader_source:find("FontSelectionView", 1, true)
    and reader_source:find("body_font_index", 1, true)
    and reader_source:find("title_font_index", 1, true), "font selection persistence is incomplete")
assert(reader_source:find("page_transition_enabled", 1, true)
    and reader_source:find("chapter_clean_wave_enabled", 1, true)
    and reader_source:find("ReaderFooter", 1, true)
    and reader_source:find("loadSwipeRefresh", 1, true)
    and reader_source:find("0.15.44/0.15.39 direct path", 1, true)
    and reader_source:find("_finishSwipeSubmission", 1, true)
    and reader_source:find("function ReaderView:refreshLayoutMenu()", 1, true)
    and reader_source:find("button.refresh", 1, true)
    and reader_source:find('UIManager:setDirty(dialog, "ui", region)', 1, true)
    and not reader_source:find("_schedulePendingMildClear", 1, true)
    and not reader_source:find("self.swipe_refresh:mildClear()", 1, true)
    and not reader_source:find("_requestInstantPage", 1, true)
    and not reader_source:find("function ReaderView:_finishInstantSubmission", 1, true)
    and not reader_source:find("refreshWaitForLast", 1, true)
    and not reader_source:find("refreshNoMergeUI", 1, true),
    "reader transition toggles/menu state must refresh locally without a full-surface mild-clear pass")
assert(swipe_source:find("ChapterWaveRefresh", 1, true)
    and swipe_source:find("SwipeAnimation", 1, true)
    and swipe_source:find("PORTRAIT_STRIPS", 1, true)
    and swipe_source:find('self.mode = "software"', 1, true)
    and swipe_source:find("local use_native = self:isNativeSwipeAvailable()", 1, true)
    and swipe_source:find("page_animation_enabled", 1, true)
    and swipe_source:find("screen.refreshUI", 1, true)
    and not swipe_source:find("function SwipeRefresh:requestInstant", 1, true)
    and not swipe_source:find("instant_replaced", 1, true)
    and not swipe_source:find("screen.refreshWaitForLast", 1, true)
    and not swipe_source:find("refreshFast", 1, true),
    "reader transitions must use native swipe or UI strip refresh without fast strips")

assert(wave_source:find("COLOR_BLACK", 1, true)
    and wave_source:find("COLOR_WHITE", 1, true)
    and wave_source:find("screen:refreshUI", 1, true)
    and wave_source:find("screen.refreshNoMergeUI", 1, true)
    and not wave_source:find("screen.refreshWaitForLast", 1, true)
    and not wave_source:find("screen.refreshFast", 1, true)
    and not wave_source:find("refreshPartial", 1, true),
    "chapter cleanup test backend must use the 0.15.45 scoped no-merge UI wave")
assert(native_source:find("canDoSwipeAnimation", 1, true)
    and native_source:find("setSwipeAnimations", 1, true)
    and native_source:find("setSwipeDirection", 1, true),
    "native page swipe must be capability-driven")
assert(reader_source:find("本章 %d%%", 1, true)
    and footer_source:find("缓存 %d/%d", 1, true),
    "reader footer must expose text progress and temporary cache status")
local footer_gap = reader_source:find("table.insert(group, UI.vspace(geometry.bottom))", 1, true)
local footer_widget = reader_source:find("table.insert(group, self:buildFooterStatus(page, geometry))", 1, true)
assert(footer_gap and footer_widget and footer_gap < footer_widget
    and reader_source:find("y = geometry.screen_height - geometry.footer_height,", 1, true)
    and reader_source:find("h = geometry.footer_height,", 1, true),
    "reader footer must keep the 0.15.39 gap above a footer flush with the bottom edge")
assert(storage_source:find("page_transition_enabled = true", 1, true)
    and storage_source:find("chapter_clean_wave_enabled = false", 1, true)
    and paginator_source:find("READER_CHROME_TOP_GAP = 14", 1, true)
    and paginator_source:find("READER_CHROME_BOTTOM_GAP = 12", 1, true)
    and paginator_source:find("READER_BODY_TOP_GAP = 24", 1, true)
    and paginator_source:find("local body_top = style.show_header and top", 1, true)
    and paginator_source:find("body_top = body_top", 1, true)
    and paginator_source:find("Screen:scaleBySize(READER_CHROME_TOP_GAP)", 1, true)
    and paginator_source:find("Screen:scaleBySize(READER_CHROME_BOTTOM_GAP)", 1, true)
    and not paginator_source:find("style.margin_top or", 1, true)
    and not paginator_source:find("style.margin_bottom or", 1, true)
    and reader_source:find("动画效果：开", 1, true)
    and reader_source:find("动画效果：关", 1, true)
    and not reader_source:find("翻页动画：", 1, true)
    and reader_source:find("跨章净屏动画：开", 1, true)
    and reader_source:find("跨章净屏动画：关", 1, true)
    and reader_source:find("UI.vspace(geometry.body_top or geometry.top)", 1, true),
    "reader animation defaults or cross-chapter cleanup label are incorrect")
assert(version_source:find('version = "0.15.47"', 1, true),
    "plugin version was not bumped to 0.15.47")
assert(install_source:find("Leko Reader 0.15.47", 1, true)
    and not install_source:find("0.15.42", 1, true)
    and not install_source:find("0.15.43", 1, true)
    and not install_source:find("0.15.45", 1, true)
    and not install_source:find("0.15.46", 1, true),
    "INSTALL.txt contains a stale release version")

print("0.15.47 targeted syntax/direct no-animation checks: OK")
