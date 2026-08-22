local plugin_root = assert(arg[1], "plugin root is required"):gsub("\\", "/")
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

package.preload["libs/libkoreader-lfs"] = function() return {} end
package.preload["util"] = function()
    return { splitToChars = function(value) return { value } end }
end

local ReaderFooter = require("Leko/ReaderFooter")

local model = {
    paragraphs = { "甲乙丙丁", "戊己庚" },
}

local start = ReaderFooter:percentage(model, {
    chapter = 3, paragraph = 1, char = 1,
}, 3, false)
local middle = ReaderFooter:percentage(model, {
    chapter = 3, paragraph = 1, char = 3,
}, 3, false)
local finish = ReaderFooter:percentage(model, {
    chapter = 3, paragraph = 2, char = 4,
}, 3, false)
assert(start == 0, "chapter start must be 0%")
assert(math.abs(middle - (2 / 7)) < 0.0001, "middle chapter percentage is incorrect")
assert(finish == 1, "chapter end must be 100%")
assert(ReaderFooter:percentage(model, {
    chapter = 4, paragraph = 1, char = 1,
}, 3, false) == 1, "next chapter position must clamp to 100%")
assert(ReaderFooter:percentage(model, {
    chapter = 3, paragraph = 99, char = 1,
}, 3, false) == 1, "invalid end paragraph must clamp to 100%")
assert(ReaderFooter:percentage(model, nil, 3, true) == 1,
    "forced end position must be 100%")

-- The text-space cache is independent of page geometry and therefore survives
-- font/line-spacing changes as long as the normalized chapter model is the same.
assert(ReaderFooter:metrics(model) == ReaderFooter:metrics(model),
    "footer progress metrics were not cached on the chapter model")

local active = ReaderFooter:prefetchLabel({ active = true, cached = 3, total = 7 })
assert(active and active.text == "缓存 3/7" and math.abs(active.percentage - 3 / 7) < 0.0001,
    "active prefetch footer label is incorrect")
assert(ReaderFooter:prefetchLabel({ active = false, cached = 7, total = 7 }) == nil,
    "completed prefetch must not remain in the footer")
assert(ReaderFooter:prefetchLabel({ status = "ready", cached = 7, total = 7 }) == nil,
    "ready prefetch must not remain in the footer")
local signature = ReaderFooter:prefetchSignature({ active = true, cached = 3, total = 7 })
assert(signature == "active:3:7", "prefetch signature did not track the count")
assert(ReaderFooter:prefetchSignature({ active = false, cached = 3, total = 7 }) == "idle",
    "inactive prefetch must use the idle signature")

-- Short, empty and unusually long paragraphs must not throw or escape bounds.
local edge_model = { paragraphs = { "", string.rep("长", 1024) } }
assert(ReaderFooter:percentage(edge_model, { chapter = 1, paragraph = 1, char = 1 }, 1, false) == 0)
assert(ReaderFooter:percentage(edge_model, { chapter = 1, paragraph = 2, char = 1025 }, 1, false) == 1)
assert(ReaderFooter:percentage({ paragraphs = {} }, { chapter = 1, paragraph = 1, char = 1 }, 1, false) == 0)

print("Reader footer text-progress, layout-stable cache hint and edge cases: OK")
