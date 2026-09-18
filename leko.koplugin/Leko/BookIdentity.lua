local BookIdentity = {}

-- Remove presentation/edition metadata only. Semantic title continuations such
-- as 续、前传、后传、番外、第二部 are deliberately retained.
local TITLE_SUFFIXES = {
    "最新章节列表", "最新章节目录", "最新章节", "章节目录", "全文免费阅读", "全文阅读",
    "小说在线阅读", "免费在线阅读", "在线阅读", "无弹窗全文阅读", "无弹窗", "完整版",
    "全集", "完结", "精校版", "校对版", "修订版", "无错版", "精校", "校对", "修订",
    "txt全集下载", "txt下载", "电子书下载", "电子书",
}

local SEMANTIC_CONTINUATIONS = {
    "续", "续集", "前传", "后传", "番外", "外传", "第二部", "第2部", "二部", "2部",
    "第三部", "第3部", "三部", "3部",
}

local BRACKET_PAIRS = {
    { "（", "）" }, { "(", ")" }, { "【", "】" }, { "[", "]" },
}

local PUNCTUATION = {
    "·", "•", "，", "。", "！", "？", "；", "：", "、", "｜", "|", "—", "–", "－", "_",
    "《", "》", "〈", "〉", "「", "」", "『", "』", "【", "】", "〔", "〕", "（", "）",
    "“", "”", "‘", "’", "…", "～", "~", "﹣", "＋", "+",
}

local OPEN_WRAPPERS = { "《", "〈", "「", "『", "【", "〔", "[" }
local CLOSE_WRAPPERS = { "》", "〉", "」", "』", "】", "〕", "]" }

local function trim(value)
    value = tostring(value or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value
end

local function utf8Length(value)
    value = tostring(value or "")
    local _, continuation = value:gsub("[\128-\191]", "")
    return #value - continuation
end

local function removePlain(value, needle)
    if needle == "" then return value end
    while true do
        local first, last = value:find(needle, 1, true)
        if not first then return value end
        value = value:sub(1, first - 1) .. value:sub(last + 1)
    end
end

local function lastPlain(value, needle)
    local start, found
    while true do
        local index = value:find(needle, start or 1, true)
        if not index then return found end
        found = index
        start = index + #needle
    end
end

local function stripOuterWrappers(value)
    local changed = true
    while changed do
        changed = false
        value = trim(value)
        for _, wrapper in ipairs(OPEN_WRAPPERS) do
            if value:sub(1, #wrapper) == wrapper then
                value = value:sub(#wrapper + 1)
                changed = true
                break
            end
        end
        value = trim(value)
        for _, wrapper in ipairs(CLOSE_WRAPPERS) do
            if #value >= #wrapper and value:sub(-#wrapper) == wrapper then
                value = value:sub(1, #value - #wrapper)
                changed = true
                break
            end
        end
    end
    return trim(value)
end

local function isPresentationSuffix(value)
    value = trim(value):lower():gsub("[%s%p%c]", "")
    for _, suffix in ipairs(TITLE_SUFFIXES) do
        local normalized = suffix:lower():gsub("[%s%p%c]", "")
        if value == normalized or value:find(normalized, 1, true) then return true end
    end
    return false
end

local function stripTrailingBrackets(value)
    local changed = true
    while changed do
        changed = false
        value = trim(value)
        for _, pair in ipairs(BRACKET_PAIRS) do
            local open, close = pair[1], pair[2]
            if #value >= #close and value:sub(-#close) == close then
                local open_pos = lastPlain(value, open)
                if open_pos then
                    local inside = value:sub(open_pos + #open, #value - #close)
                    if isPresentationSuffix(inside) then
                        value = value:sub(1, open_pos - 1)
                        changed = true
                        break
                    end
                end
            end
        end
    end
    return trim(value)
end

local function stripKnownSuffixes(value)
    local changed = true
    while changed do
        changed = false
        value = trim(value)
        local lower = value:lower()
        for _, suffix in ipairs(TITLE_SUFFIXES) do
            local needle = suffix:lower()
            if #lower >= #needle and lower:sub(-#needle) == needle then
                value = value:sub(1, #value - #suffix)
                changed = true
                break
            end
        end
    end
    return trim(value)
end

local function removePunctuation(value)
    value = value:gsub("[%s%p%c]", "")
    for _, token in ipairs(PUNCTUATION) do value = removePlain(value, token) end
    return value
end

local function hasSemanticContinuation(extra)
    extra = tostring(extra or "")
    for _, marker in ipairs(SEMANTIC_CONTINUATIONS) do
        if extra:sub(1, #marker) == marker then return true end
    end
    return false
end

function BookIdentity:normalizeTitle(value)
    value = trim(value):lower():gsub("　", " ")
    value = value:gsub("^%s*书名%s*[：:]?%s*", "")
    local author_pos = value:find("作者：", 1, true) or value:find("作者:", 1, true)
    if author_pos then value = value:sub(1, author_pos - 1) end
    value = stripOuterWrappers(value)
    value = stripTrailingBrackets(value)
    value = stripKnownSuffixes(value)
    value = stripOuterWrappers(value)
    return removePunctuation(value)
end

function BookIdentity:sameTitle(left, right)
    local a = self:normalizeTitle(left)
    local b = self:normalizeTitle(right)
    return a ~= "" and b ~= "" and a == b
end

function BookIdentity:normalizeAuthor(value)
    value = trim(value):lower():gsub("　", " ")
    value = value:gsub("^%s*作者%s*[：:]?%s*", "")
    value = value:gsub("^%s*author%s*[：:]?%s*", "")
    value = value:gsub("^%s*by%s+", "")
    value = value:gsub("%s*[著着]%s*$", "")
    value = value:gsub("%s*作品%s*$", "")
    return removePunctuation(value)
end

function BookIdentity:authorDiffers(left, right)
    local a = self:normalizeAuthor(left)
    local b = self:normalizeAuthor(right)
    return a ~= "" and b ~= "" and a ~= b
end

-- Ordinary search classification. Source/cover switching never uses fuzzy
-- matching: those modes require sameTitle() after normalization.
function BookIdentity:searchMatch(keyword, title, author)
    local title_query = self:normalizeTitle(keyword)
    local author_query = self:normalizeAuthor(keyword)
    local normalized_title = self:normalizeTitle(title)
    local normalized_author = self:normalizeAuthor(author)

    if title_query ~= "" and normalized_title ~= "" and normalized_title == title_query then
        return 1000, "exact-title"
    end
    if author_query ~= "" and normalized_author ~= "" then
        if normalized_author == author_query then return 920, "author" end
        if utf8Length(author_query) >= 2 and normalized_author:find(author_query, 1, true) then
            return 760, "author"
        end
    end
    if title_query ~= "" and normalized_title ~= "" then
        -- Partial title matches are admitted for every query length.  An exact
        -- hit already returned above, so this branch only ranks the remainder:
        -- a hit anchored at the start of the title outranks one found in the
        -- middle.  Gating this on one- and two-character queries made ordinary
        -- Chinese searches return nothing at all -- "十日终" never matched
        -- "十日终焉", so the entire result set was dropped before reaching the
        -- list.  That failure is invisible: no source error and no skipped
        -- source, the list just stays empty.  Longer queries are the *more*
        -- precise case, so the old length gate had the noise trade-off
        -- backwards.
        local anchor = normalized_title:find(title_query, 1, true)
        if anchor then
            return anchor == 1 and 700 or 620, "related-title"
        end
    end
    return nil
end

function BookIdentity:searchScore(keyword, title, author)
    local score = self:searchMatch(keyword, title, author)
    return score
end

function BookIdentity:bestSearchResult(results, keyword)
    local best, best_score, best_kind, best_order
    for index, item in ipairs(type(results) == "table" and results or {}) do
        local score, kind = self:searchMatch(keyword, item and item.title, item and item.author)
        if score and (not best_score or score > best_score or score == best_score and index < best_order) then
            best, best_score, best_kind, best_order = item, score, kind, index
        end
    end
    return best, best_score, best_kind
end

-- Ranked variant of bestSearchResult for aggregate sources (书山原生): one
-- upstream search returns many distinct books, so collapsing to the single
-- best row throws away everything the user searched for.  Scores every row,
-- drops near-duplicates (same normalized title+author — the aggregate repeats
-- the same book across dozens of mirror sites), sorts by score and returns at
-- most max_n entries as { item, score, kind } records.
function BookIdentity:rankedSearchResults(results, keyword, max_n)
    max_n = tonumber(max_n) or 10
    -- Author voting: among rows whose title is an exact match for the keyword,
    -- the most common author is almost always the original book's author
    -- (dozens of mirror sites), while same-title impostors (fanfic, pirated
    -- one-chapter stubs) each carry their own author string.  Boosting the
    -- majority author sinks impostors without rejecting them outright.
    local kw_norm = self:normalizeTitle(keyword)
    local votes = {}
    for _, item in ipairs(type(results) == "table" and results or {}) do
        if self:normalizeTitle(item and item.title) == kw_norm then
            local a = trim(item and item.author)
            if a ~= "" then votes[a] = (votes[a] or 0) + 1 end
        end
    end
    local top_author, top_votes = nil, 1
    for a, n in pairs(votes) do
        if n > top_votes then top_author, top_votes = a, n end
    end
    local scored = {}
    for index, item in ipairs(type(results) == "table" and results or {}) do
        local score, kind = self:searchMatch(keyword, item and item.title, item and item.author)
        if score then
            -- 不去重：同一本书的多个站点镜像各占一行（每行带站点徽标），
            -- Sean 要求全部展示；排序靠作者投票加权保证真书行在前。
            local boost = 0
            if self:normalizeTitle(item and item.title) == kw_norm and top_author then
                local a = trim(item and item.author)
                if a == top_author then
                    boost = 10
                elseif a == "" then
                    boost = 4
                end
            end
            scored[#scored + 1] = { item = item, score = score + boost, kind = kind, order = index }
        end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.order < b.order
    end)
    local out = {}
    for i = 1, math.min(#scored, max_n) do
        out[#out + 1] = scored[i]
    end
    return out
end

function BookIdentity:bestExactTitle(results, wanted_title, wanted_author, prefer_cover)
    local best, best_score
    for _, item in ipairs(type(results) == "table" and results or {}) do
        if self:sameTitle(wanted_title, item and item.title) then
            local score = 100
            if trim(item.title) == trim(wanted_title) then score = score + 20 end
            -- Author is a tie-breaker only. A different author never rejects a
            -- same-title source, because imported sources frequently rename it.
            if not self:authorDiffers(wanted_author, item and item.author) then score = score + 8 end
            if tostring(item and item.book_url or "") ~= "" then score = score + 4 end
            if prefer_cover and tostring(item and item.cover or "") ~= "" then score = score + 3 end
            if not best_score or score > best_score then best, best_score = item, score end
        end
    end
    return best, best_score
end

return BookIdentity

