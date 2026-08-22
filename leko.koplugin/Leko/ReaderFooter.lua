-- Reader footer calculations.
--
-- This module deliberately knows nothing about fonts, page counts, widgets or
-- refresh policy.  It only maps a normalized chapter position to a stable
-- text-progress percentage and describes whether the temporary prefetch hint
-- is currently active.

local Util = require("Leko/Util")

local ReaderFooter = {}

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function normalizePosition(position)
    position = position or {}
    return {
        chapter = tonumber(position.chapter) or 1,
        paragraph = tonumber(position.paragraph) or 1,
        char = tonumber(position.char) or 1,
    }
end

-- Build the cache from the already-loaded normalized paragraph model.  It is
-- attached to that model so a font/layout change reuses the same text-space
-- denominator without scanning or paginating the chapter again.
function ReaderFooter:metrics(model)
    if type(model) ~= "table" then return nil end
    if type(model._leko_footer_progress) == "table" then
        return model._leko_footer_progress
    end

    local prefixes = {}
    local lengths = {}
    local total = 0
    for index, paragraph in ipairs(model.paragraphs or {}) do
        prefixes[index] = total
        local length = math.max(0, Util.utf8Length(tostring(paragraph or "")))
        lengths[index] = length
        total = total + length
    end

    local result = {
        prefixes = prefixes,
        lengths = lengths,
        total = total,
        paragraph_count = #(model.paragraphs or {}),
    }
    model._leko_footer_progress = result
    return result
end

function ReaderFooter:percentage(model, page_position, chapter_index, force_end)
    local metrics = self:metrics(model)
    if not metrics then return 0 end
    if force_end then return 1 end

    local position = normalizePosition(page_position)
    chapter_index = tonumber(chapter_index) or position.chapter
    if position.chapter > chapter_index then return 1 end
    if position.chapter < chapter_index then return 0 end
    if metrics.total <= 0 then return 0 end

    local paragraph_count = metrics.paragraph_count
    if paragraph_count <= 0 then return 0 end
    if position.paragraph > paragraph_count then return 1 end
    local paragraph = clamp(math.floor(position.paragraph), 1, paragraph_count)
    local length = metrics.lengths[paragraph] or 0
    local char = clamp(math.floor(position.char), 1, length + 1)
    local consumed = (metrics.prefixes[paragraph] or 0) + char - 1
    return clamp(consumed / metrics.total, 0, 1)
end

function ReaderFooter:isPrefetchActive(state)
    return type(state) == "table"
        and state.active == true
        and tonumber(state.total or 0) > 0
end

function ReaderFooter:prefetchSignature(state)
    if not self:isPrefetchActive(state) then return "idle" end
    local cached = math.max(0, math.min(
        tonumber(state.total) or 0, tonumber(state.cached or 0) or 0))
    return table.concat({ "active", tostring(cached), tostring(tonumber(state.total) or 0) }, ":")
end

function ReaderFooter:prefetchLabel(state)
    if not self:isPrefetchActive(state) then return nil end
    local total = math.max(1, tonumber(state.total) or 1)
    local cached = math.max(0, math.min(total, tonumber(state.cached or 0) or 0))
    return {
        text = string.format("缓存 %d/%d", cached, total),
        cached = cached,
        total = total,
        percentage = clamp(cached / total, 0, 1),
    }
end

return ReaderFooter
