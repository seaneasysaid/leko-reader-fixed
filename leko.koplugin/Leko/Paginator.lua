local Font = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Screen = require("device").screen
local BookService = require("Leko/BookService")
local Util = require("Leko/Util")
local ReaderMargins = require("Leko/ReaderMargins")
local logger = require("logger")

local Paginator = {}

-- The reading area is inset from the physical screen edges by the
-- user-facing 上下边距 (margin_top/margin_bottom). The constants below are
-- only fallback chrome gaps for styles that predate the vertical margin
-- setting, so older installations keep their original geometry.
local READER_CHROME_TOP_GAP = 5
local READER_CHROME_BOTTOM_GAP = 5
-- When the header is hidden, keep the body away from the physical top edge
-- by an extra base inset on top of the user margin. This preserves the
-- 0.15.39-sized reading inset without making the visible header's own outer
-- gap as large as the user margin.
local READER_BODY_TOP_GAP = 24

local IDEOGRAPHIC_SPACE = "\u{3000}"
local NO_BREAK_SPACE = "\u{00A0}"
local SYSTEM_FONT = "cfont"
-- 段评气泡的样式对齐番茄插件（那边是 crengine 的行内 `<a class="para-comment">`，
-- CSS 为 `font-size: 0.8em !important; font-weight: bold; margin: 0 1px`）：
-- 字号 = 正文字号 × 这个比例，字体族用正文那一套，并加粗。
-- 见 getGeometry 里的 para_marker_face / para_marker_bold。
local PARA_MARKER_FONT_RATIO = 0.80
local PARA_MARKER_BOLD = true
-- 气泡与段末文字之间的缝（≈ CSS 的 margin-left: 1px）。分页器把它算进预留宽度、
-- 渲染层按 geometry 里同一个值摆放，两边不会打架。
local PARA_MARKER_GAP = 2
local SYSTEM_FONT_DISPLAY_NAME = "系统默认（简体中文优先）"

local function resolveReaderFace(style, font_field, index_field, display_field, size)
    local path = tostring(style[font_field] or SYSTEM_FONT)
    local index = tonumber(style[index_field])
    local ok, face
    if index == nil then
        ok, face = pcall(Font.getFace, Font, path, size)
    else
        ok, face = pcall(Font.getFace, Font, path, size, index)
    end
    if ok and face then return face end

    if path ~= SYSTEM_FONT then
        -- Keep Font.faces intact: KOReader owns that cache and clearing it can
        -- invalidate faces still used by the current page. Only repair this
        -- reader style, then let ReaderView show one friendly notification.
        style[font_field] = SYSTEM_FONT
        style[index_field] = nil
        style[display_field] = SYSTEM_FONT_DISPLAY_NAME
        local paired_field = font_field == "body_font" and "title_font" or "body_font"
        local paired_index = paired_field == "body_font" and "body_font_index" or "title_font_index"
        local paired_display = paired_field == "body_font" and "body_font_display_name" or "title_font_display_name"
        if tostring(style[paired_field] or "") == path then
            style[paired_field] = SYSTEM_FONT
            style[paired_index] = nil
            style[paired_display] = SYSTEM_FONT_DISPLAY_NAME
        end
        style._font_fallback_pending = true
        local fallback_ok, fallback = pcall(Font.getFace, Font, SYSTEM_FONT, size)
        if fallback_ok and fallback then return fallback end
    end
    error("系统默认字体无法加载")
end

-- Legado's HTML formatter keeps paragraph indentation in parsed content.
-- Normalize that presentation whitespace here so the reader setting remains
-- authoritative without changing cached source text or Legado rule semantics.
local function leadingIndentChars(value)
    value = tostring(value or "")
    local byte_index = 1
    local char_count = 0
    while byte_index <= #value do
        local byte = value:sub(byte_index, byte_index)
        if byte == " " or byte == "\t" then
            byte_index = byte_index + 1
            char_count = char_count + 1
        elseif value:sub(byte_index, byte_index + #NO_BREAK_SPACE - 1) == NO_BREAK_SPACE then
            byte_index = byte_index + #NO_BREAK_SPACE
            char_count = char_count + 1
        elseif value:sub(byte_index, byte_index + #IDEOGRAPHIC_SPACE - 1) == IDEOGRAPHIC_SPACE then
            byte_index = byte_index + #IDEOGRAPHIC_SPACE
            char_count = char_count + 1
        else
            break
        end
    end
    return char_count
end

-- First-line indentation is measured in full-width ideographic spaces.
-- style.indent accepts false (off), an explicit character count (2 or 4),
-- or the legacy boolean true (interpreted as 2 characters).
local function indentPrefix(style)
    if style.indent == false then return "", 0 end
    local count = tonumber(style.indent) or 2
    if count < 1 then count = 2 elseif count > 8 then count = 8 end
    return string.rep(IDEOGRAPHIC_SPACE, count), count
end

local function bodyMetrics(style)
    local face = resolveReaderFace(style, "body_font", "body_font_index",
        "body_font_display_name", style.body_font_size or 27)
    local probe = TextBoxWidget:new{
        text = "测",
        face = face,
        width = math.max(20, Screen:getWidth() - 20),
        line_height = style.line_spacing or 0.28,
        lang = "zh-CN",
        bold = false,
        for_measurement_only = true,
    }
    local height = probe.line_height_px
    if probe.free then probe:free() end
    return face, height
end

local function measuredHeight(widget)
    local size = widget and widget.getSize and widget:getSize()
    return math.max(1, math.ceil((size and size.h) or 1))
end

local function smallTextHeight(face)
    local widget = TextWidget:new{ text = "测", face = face, padding = 0 }
    return measuredHeight(widget)
end

function Paginator:getGeometry(style)
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local left = Screen:scaleBySize(style.margin_left or 28)
    local right = Screen:scaleBySize(style.margin_right or 28)
    local top = Screen:scaleBySize(style.margin_top or READER_CHROME_TOP_GAP)
    local bottom = Screen:scaleBySize(style.margin_bottom or READER_CHROME_BOTTOM_GAP)
    local content_width = math.max(Screen:scaleBySize(120), screen_width - left - right)

    local body_face, body_line_height = bodyMetrics(style)
    -- Whole Chinese glyphs can leave unused space at the end of every full
    -- line. Share that remainder between the margins instead of putting all
    -- of it on the right. Use the renderer's measured advance, not font size.
    local width_probe = TextWidget:new{ text = "测", face = body_face, padding = 0,
        lang = "zh-CN", bold = false }
    local cell_width = width_probe:getSize().w
    if width_probe.free then width_probe:free() end
    if cell_width and cell_width > 0 and cell_width <= content_width then
        local fitted_width = math.floor(content_width / cell_width) * cell_width
        if (style.margin_left or 28) == (style.margin_right or 28) then
            local preset = ReaderMargins:index(style.margin_left or 28)
            if preset then
                fitted_width = ReaderMargins:columns(preset, screen_width, cell_width,
                    function(value) return Screen:scaleBySize(value) end) * cell_width
            end
        end
        local remainder = content_width - fitted_width
        local left_extra = math.floor(remainder / 2)
        left = left + left_extra
        right = right + remainder - left_extra
        content_width = fitted_width
    end
    local chrome_face = Font:getFace("smallinfofont", 17)
    local chrome_height = smallTextHeight(chrome_face)
    -- 段评气泡用**正文那一套字体**的小一号（正文的 80%，最小 11px）+ 粗体 ——
    -- 番茄插件的 `a.para-comment` 就是这个规格（0.8em / bold / 行内跟随正文字体），
    -- 读者自定义的中文字体在这个尺寸上通常比 smallinfofont 更像正文。
    -- 必须是**固定**的一档：分页器按这个 face 给段末行预留宽度（fitBodyLines 的
    -- tail_reserve），渲染层按它画气泡 —— 两边要是用了不同的 face，气泡就会偏出
    -- 命中区，读者点气泡会变成翻页。
    local marker_size = math.max(11,
        math.floor((tonumber(style.body_font_size) or 27) * PARA_MARKER_FONT_RATIO))
    -- resolveReaderFace 在字体坏掉时会改写 style 作为修复。bodyMetrics 刚跑过一次，
    -- 正常情况下这里必定成功；真失败也只是气泡退回小字号，不该让分页整页失败。
    local marker_ok, marker_face = pcall(resolveReaderFace, style, "body_font",
        "body_font_index", "body_font_display_name", marker_size)
    local para_marker_face = (marker_ok and marker_face)
        or Font:getFace("smallinfofont", marker_size)
    -- Small fixed gap between the physical top edge and the header, so the
    -- header does not touch the screen edge. Only reserve it while the
    -- header is actually shown; with a hidden header the body starts at
    -- body_top and the footer must still reach the physical bottom edge.
    local header_offset = style.show_header and Screen:scaleBySize(5) or 0
    local header_height = style.show_header and chrome_height + Screen:scaleBySize(2) or 0
    -- The reading menu is an overlay, not a permanent button bar. Reserve only
    -- a compact optional status footer so the text area behaves like a reader.
    local footer_height = style.show_footer and (chrome_height + Screen:scaleBySize(2)) or 0
    local control_height = 0
    -- When the header is hidden the body keeps its own base inset from the
    -- physical top edge; the user margin adds on top of that base gap. When
    -- the header is visible, body_top is the 上边距 between the header and
    -- the first body line (the header itself only adds header_offset above).
    local body_top = style.show_header and top
        or (Screen:scaleBySize(READER_BODY_TOP_GAP) + top - Screen:scaleBySize(READER_CHROME_TOP_GAP))
    local content_height = screen_height - header_offset - body_top - bottom - header_height - footer_height

    return {
        screen_width = screen_width,
        screen_height = screen_height,
        left = left,
        right = right,
        top = top,
        body_top = body_top,
        bottom = bottom,
        content_width = content_width,
        content_height = math.max(body_line_height, content_height),
        body_face = body_face,
        body_line_height = body_line_height,
        chrome_face = chrome_face,
        para_marker_face = para_marker_face,
        para_marker_bold = PARA_MARKER_BOLD,
        para_marker_gap = Screen:scaleBySize(PARA_MARKER_GAP),
        header_offset = header_offset,
        header_height = header_height,
        footer_height = footer_height,
        control_height = control_height,
    }
end


-- 量一个短串在给定 face 下的像素宽度。段评气泡要按它给段末行让位，而渲染层用
-- 同一个 TextWidget 配置画气泡，两边量出来的宽度才一致。
--
-- bold 必须与渲染层传的一致：TextWidget 内部会走 Font:getAdjustedFace，
-- 若正文那一族存在**真实的粗体变体**，调整后的 face 字宽会变 —— 只在一侧加粗
-- 会让预留宽度与气泡实际宽度对不上，气泡就偏出命中区了。
local function measureTextWidth(value, face, bold)
    local widget = TextWidget:new{ text = tostring(value or ""), face = face,
        padding = 0, lang = "zh-CN", bold = bold == true }
    local size = widget:getSize()
    local width = math.max(0, math.ceil((size and size.w) or 0))
    if widget.free then widget:free() end
    return width
end

local function paragraphLength(model, paragraph_index)
    model._utf8_lengths = model._utf8_lengths or {}
    local cached = model._utf8_lengths[paragraph_index]
    if cached ~= nil then return cached end
    local paragraph = model.paragraphs[paragraph_index] or ""
    local length = Util.utf8Length(paragraph)
    -- Whitespace at the end has no visible reading position. Keep the source
    -- text intact and its character offsets stable, but do not paginate an
    -- ideographic-space-only paragraph (or the tail of a long paragraph).
    local last = #paragraph
    while last > 0 do
        local first = last
        while first > 1 and paragraph:byte(first) >= 128 and paragraph:byte(first) < 192 do
            first = first - 1
        end
        local char = paragraph:sub(first, last)
        if not char:match("^%s$") and char ~= IDEOGRAPHIC_SPACE and char ~= NO_BREAK_SPACE
                and char ~= "\u{200B}" and char ~= "\u{FEFF}" then break end
        length, last = length - 1, first - 1
    end
    model._utf8_lengths[paragraph_index] = length
    return length
end

local function chapterId(book, chapter_index)
    local chapter = book and book.chapters and book.chapters[chapter_index]
    return chapter and chapter.id or nil
end

local function makePosition(book, chapter_index, paragraph_index, char_index)
    return {
        chapter = chapter_index,
        chapter_id = chapterId(book, chapter_index),
        paragraph = paragraph_index,
        char = char_index,
    }
end

-- Resolve a page boundary inside the already loaded chapter only. In
-- particular, a full last text row followed by blank paragraphs is the last
-- page, not a promise to render another empty screen on the next tap.
local function finishPage(book, model, page)
    local next_position = page.next_position
    if not next_position or next_position.chapter ~= page.chapter_index then return page end
    while next_position.paragraph <= #model.paragraphs do
        if next_position.char <= paragraphLength(model, next_position.paragraph) then return page end
        next_position.paragraph = next_position.paragraph + 1
        next_position.char = 1
    end
    if page.chapter_index < #book.chapters then
        page.next_position = makePosition(book, page.chapter_index + 1, 1, 1)
    else
        page.next_position = makePosition(book, page.chapter_index, #model.paragraphs,
            paragraphLength(model, #model.paragraphs) + 1)
        page.at_end = true
    end
    return page
end

local function normalizePosition(book, position)
    position = Util.positionCopy(position)
    if position.chapter < 1 then position.chapter = 1 end
    if position.chapter > #book.chapters then position.chapter = #book.chapters end
    if position.paragraph < 1 then position.paragraph = 1 end
    if position.char < 1 then position.char = 1 end
    local current_id = chapterId(book, position.chapter)
    if position.chapter_id ~= nil and tostring(position.chapter_id) ~= tostring(current_id) then
        position.paragraph = 1
        position.char = 1
    end
    position.chapter_id = current_id
    return position
end

function Paginator:_advanceToValid(book, position)
    position = normalizePosition(book, position)
    while position.chapter <= #book.chapters do
        local model, err = BookService:loadChapterModel(book, position.chapter)
        if not model then return nil, err end
        if position.paragraph > #model.paragraphs then
            if position.chapter >= #book.chapters then
                return {
                    chapter = #book.chapters,
                    chapter_id = chapterId(book, #book.chapters),
                    paragraph = #model.paragraphs,
                    char = paragraphLength(model, #model.paragraphs) + 1,
                    at_end = true,
                }
            end
            position = makePosition(book, position.chapter + 1, 1, 1)
        else
            local length = paragraphLength(model, position.paragraph)
            if position.char > length then
                position.paragraph = position.paragraph + 1
                position.char = 1
            else
                return position, nil, model
            end
        end
    end
    return nil, "已到书籍末尾"
end

local function makeMeasureWidget(text, face, width, line_spacing, alignment, bold)
    return TextBoxWidget:new{
        text = text,
        face = face,
        width = width,
        line_height = line_spacing,
        lang = "zh-CN",
        bold = bold == true,
        alignment = alignment or "left",
        alignment_strict = true,
        for_measurement_only = true,
    }
end

-- Use the same single-line fitter and renderer as TextWidget. In contrast to
-- TextBoxWidget paragraph wrapping, makeLine(..., true) fills the available
-- width instead of moving otherwise fitting glyphs to obey break preferences.
-- One bounded window is measured once; no paragraph/glyph records survive it.
--[[--
把一段文本按可用宽度贪心切成若干行。

`tail_reserve` 是给**最后一行**末尾的段评标记预留的宽度（不需要段评时传 nil，行为
与改动前完全一致）。标记只挂在一段的最后一行，所以这里刻意不改动前面的行：

  1. 先按整宽贪心求行；
  2. 末行本来就装得下标记（整宽 - 末行实际宽度 >= 预留）→ 完全不重排；
  3. 装不下 → 从末行起点起，用「整宽 - 预留」重排末行及它挤出来的后续行。

这样只有真正需要让位的那一段末行会变短，其余行和整体分页都不受影响。
]]--
local function fitBodyLines(text, chars, face, width, bold, tail_reserve)
    local probe = TextWidget:new{ text = text, face = face, padding = 0,
        lang = "zh-CN", bold = bold == true }
    probe:getSize()
    local function fitEnd(offset, limit)
        local last
        if probe._xtext then
            local line = probe._xtext:makeLine(offset, limit, true)
            last = line.end_offset
        else
            local RenderText = require("ui/rendertext")
            local fitted = RenderText:getSubTextByWidth(table.concat(chars, "", offset), face, limit, true, false)
            last = offset + Util.utf8Length(fitted) - 1
        end
        return math.min(#chars, math.max(offset, tonumber(last) or offset))
    end

    local lines, offset = {}, 1
    while offset <= #chars do
        local last = fitEnd(offset, width)
        lines[#lines + 1] = { offset = offset, end_offset = last }
        offset = last + 1
    end

    local reserve = tonumber(tail_reserve) or 0
    local narrowed = width - reserve
    if reserve > 0 and narrowed >= 1 and next(lines) ~= nil then
        local tail_start = lines[#lines].offset
        local tail_text = table.concat(chars, "", tail_start, lines[#lines].end_offset)
        local tail_probe = TextWidget:new{ text = tail_text, face = face, padding = 0,
            lang = "zh-CN", bold = bold == true }
        local tail_size = tail_probe:getSize()
        local tail_width = tail_size and tail_size.w or 0
        if tail_probe.free then tail_probe:free() end
        if tail_width + reserve > width then
            local head = {}
            for index = 1, #lines - 1 do head[index] = lines[index] end
            local scan = tail_start
            while scan <= #chars do
                local last = fitEnd(scan, narrowed)
                head[#head + 1] = { offset = scan, end_offset = last }
                scan = last + 1
            end
            lines = head
        end
    end

    if probe.free then probe:free() end
    return lines
end

function Paginator:makePage(book, requested_position, style)
    local position, err, model = self:_advanceToValid(book, requested_position)
    if not position then return nil, err end
    if position.at_end then return nil, "已到书籍末尾" end

    local geometry = self:getGeometry(style)
    -- A source paragraph may open with an ideographic-space placeholder row
    -- (e.g. "\u3000\u3000\u3000\u3000") that paragraphLength counts as zero
    -- characters, so _advanceToValid has already moved (ch,1,1) on to
    -- (ch,2,1). Judge the chapter start the same way isChapterStart does
    -- (compare against the normalized (ch,1,1) resolution) instead of the
    -- raw advanced position, or the opening title would never be emitted.
    local at_chapter_start = self:isChapterStart(book, position)
    local show_header = style.show_header
    if not show_header and geometry.header_height > 0 then
        geometry.content_height = geometry.content_height + geometry.header_height
        geometry.header_height = 0
    end
    local page = {
        start_position = Util.positionCopy(position),
        next_position = nil,
        -- ReaderView's footer uses the same model that pagination just loaded.
        -- Keeping this one current-chapter reference avoids a second lookup on
        -- every ordinary page turn without creating a page cache.
        chapter_model = model,
        elements = {},
        chapter_index = position.chapter,
        chapter_title = model.title,
        geometry = geometry,
        style = style,
        used_height = 0,
        at_end = false,
        is_chapter_start = at_chapter_start,
        show_header = show_header,
    }

    local remaining_height = geometry.content_height

    if at_chapter_start then
        local title_face = resolveReaderFace(style, "title_font", "title_font_index",
            "title_font_display_name", style.title_font_size or 34)
        local title_bold = style.title_bold ~= false
        local title_measure = makeMeasureWidget(model.title, title_face, geometry.content_width,
            0.18, "left", title_bold)
        local title_height = measuredHeight(title_measure)
        if title_measure.free then title_measure:free() end
        local top_gap, bottom_gap
        if (tonumber(style.layout_version or 2) or 2) >= 2 then
            -- The opening is a proportion of the physical page, not a Kindle
            -- 7-only pixel constant. Keep the first body line around 36% of
            -- the page, then center the title vertically in the physical
            -- opening between the top edge and that body line. The title
            -- remains left aligned with the body; only its Y position moves.
            local body_y = math.floor(geometry.screen_height * 0.36)
            local title_y = math.floor((body_y - title_height) / 2)
            top_gap = math.max(0, title_y - geometry.body_top)
            bottom_gap = math.max(0, body_y - geometry.body_top - top_gap - title_height)
        else
            top_gap = Screen:scaleBySize(style.title_margin_top or 44)
            bottom_gap = Screen:scaleBySize(style.title_margin_bottom or 54)
        end
        local total = top_gap + title_height + bottom_gap
        -- Never emit a title-only page with an unchanged next position.
        -- Keep room for at least one body line; otherwise start with body text.
        if total + geometry.body_line_height <= remaining_height then
            table.insert(page.elements, {
                type = "title",
                text = model.title,
                height = title_height,
                top_gap = top_gap,
                bottom_gap = bottom_gap,
                face = title_face,
                bold = title_bold,
                line_height = 0.18,
                alignment = "left",
            })
            page.used_height = page.used_height + total
            remaining_height = remaining_height - total
        else
            -- 页面放不下标题+一行正文时，直接以正文开头。
        end
    end

    local chapter_index = position.chapter
    local paragraph_index = position.paragraph
    local char_index = position.char
    local paragraph_gap = Screen:scaleBySize(style.paragraph_spacing or 10)
    local added_line = false
    -- A source may return an entire chapter as one physical line. Shaping the
    -- complete remaining paragraph just to draw one screen can freeze a Kindle 7
    -- and briefly duplicate tens of thousands of UTF-8 characters. Measure only a
    -- bounded forward window; a normal page consumes far fewer characters.
    local max_measure_chars = 768
    model._utf8_hints = model._utf8_hints or {}

    while chapter_index == position.chapter and paragraph_index <= #model.paragraphs do
        local paragraph = model.paragraphs[paragraph_index]
        local paragraph_length = paragraphLength(model, paragraph_index)
        -- 段评（可选）：本段有评论时，段末行尾部要挂一个 [N] 气泡。
        -- 计数表由 ParaComments 预先放进 model.para_counts（纯内存查询，
        -- 分页过程本身绝不发网络请求）；段落号是服务端给的 0 基非空段序号。
        local paragraph_marker = nil
        local marker_width = 0
        if style.para_review_enabled == true and type(model.para_counts) == "table" then
            local count = tonumber(model.para_counts[paragraph_index - 1])
            if count and count > 0 then
                -- 超过 99 条就只说「99+」：三位数会把段末行的留白撑得太宽，
                -- 而读者也不必知道到底是 137 条还是 349 条。
                paragraph_marker = count > 99 and "[99+]"
                    or ("[" .. tostring(math.floor(count)) .. "]")
                marker_width = measureTextWidth(paragraph_marker,
                    geometry.para_marker_face or geometry.body_face,
                    geometry.para_marker_bold) + (geometry.para_marker_gap or 0)
                -- 极端计数不该把正文挤成窄条。
                marker_width = math.min(marker_width, math.floor(geometry.content_width / 6))
            end
        end
        local paragraph_done = false
        while not paragraph_done do
            local prefix = ""
            local prefix_length = 0
            local content_char_index = char_index
            if char_index == 1 then
                content_char_index = char_index + leadingIndentChars(paragraph)
                prefix, prefix_length = indentPrefix(style)
            end
            if content_char_index > paragraph_length then
                paragraph_done = true
                break
            end
            local hint = model._utf8_hints[paragraph_index]
            local window_text, window_count, has_more, next_byte = Util.utf8Window(
                paragraph, content_char_index, math.min(max_measure_chars, paragraph_length - content_char_index + 1),
                hint and hint.char, hint and hint.byte)
            has_more = content_char_index + window_count <= paragraph_length
            if window_count <= 0 then
                paragraph_done = true
                break
            end
            local layout_text = prefix .. window_text
            -- This table is now strictly bounded instead of mirroring the full
            -- chapter-sized paragraph.
            local layout_chars = Util.utf8Chars(layout_text)
            -- 只有「本段最后一行落在这一批里」时才需要为气泡让位；中间的窗口
            -- 不传预留宽度，分页结果与没有段评时完全相同。
            local tail_reserve = (marker_width > 0 and not has_more) and marker_width or nil
            local lines = fitBodyLines(layout_text, layout_chars, geometry.body_face,
                geometry.content_width, false, tail_reserve)
            if has_more and #lines > 1 then
                -- Refill the final window row before painting it.
                local tail = table.remove(lines)
                window_count = tail.offset - 1 - prefix_length
                next_byte = next_byte - #table.concat(layout_chars, "", tail.offset)
            end

            for line_index, line in ipairs(lines) do
                if line.end_offset and line.end_offset >= line.offset then
                    if geometry.body_line_height > remaining_height and (added_line or #page.elements > 0) then
                        local next_layout_offset = line.offset
                        local next_char = content_char_index + math.max(0, next_layout_offset - prefix_length - 1)
                        page.next_position = makePosition(book, chapter_index, paragraph_index, next_char)
                        return finishPage(book, model, page)
                    end

                    local text = table.concat(layout_chars, "", line.offset, line.end_offset)
                    local next_line = lines[line_index + 1]
                    local next_layout_offset = next_line and next_line.offset or (prefix_length + window_count + 1)
                    local next_char = content_char_index + math.max(0, next_layout_offset - prefix_length - 1)
                    local is_last_line = line_index == #lines

                    table.insert(page.elements, {
                        type = "line",
                        text = text,
                        height = geometry.body_line_height,
                        paragraph = paragraph_index,
                        start_char = content_char_index + math.max(0, line.offset - prefix_length - 1),
                        next_char = next_char,
                        paragraph_end = is_last_line and not has_more,
                        -- 段评气泡只落在本段最后一行；它是渲染层要画的文本，
                        -- 也是点击命中区（矩形）的依据。
                        para_marker = (is_last_line and not has_more) and paragraph_marker or nil,
                    })
                    page.used_height = page.used_height + geometry.body_line_height
                    remaining_height = remaining_height - geometry.body_line_height
                    added_line = true

                    if not is_last_line and remaining_height < geometry.body_line_height then
                        page.next_position = makePosition(book, chapter_index, paragraph_index, next_char)
                        return finishPage(book, model, page)
                    end
                end
            end

            if has_more then
                char_index = content_char_index + window_count
                model._utf8_hints[paragraph_index] = next_byte and { char = char_index, byte = next_byte } or nil
                if remaining_height < geometry.body_line_height then
                    page.next_position = makePosition(book, chapter_index, paragraph_index, char_index)
                    return finishPage(book, model, page)
                end
            else
                paragraph_done = true
            end
        end

        paragraph_index = paragraph_index + 1
        char_index = 1
        while paragraph_index <= #model.paragraphs and paragraphLength(model, paragraph_index) == 0 do
            paragraph_index = paragraph_index + 1
        end
        if paragraph_index <= #model.paragraphs then
            if paragraph_gap + geometry.body_line_height <= remaining_height then
                table.insert(page.elements, { type = "gap", height = paragraph_gap })
                page.used_height = page.used_height + paragraph_gap
                remaining_height = remaining_height - paragraph_gap
            elseif added_line then
                page.next_position = makePosition(book, chapter_index, paragraph_index, 1)
                return finishPage(book, model, page)
            end
        end
    end

    if chapter_index < #book.chapters then
        page.next_position = makePosition(book, chapter_index + 1, 1, 1)
    else
        page.next_position = makePosition(book, chapter_index, #model.paragraphs,
            paragraphLength(model, #model.paragraphs) + 1)
        page.at_end = true
    end
    return page
end

function Paginator:isChapterStart(book, position)
    if position.paragraph == 1 and position.char == 1 then return true end
    local first = self:_advanceToValid(book, makePosition(book, position.chapter, 1, 1))
    return first and Util.positionEqual(first, position) or false
end

local function previousSearchStart(book, target_position)
    local chapter_index = target_position.chapter
    local paragraph_index = target_position.paragraph
    local char_index = target_position.char

    if paragraph_index == 1 and char_index == 1 then
        chapter_index = chapter_index - 1
        if chapter_index < 1 then return nil, "已经是第一页" end
        local model, err = BookService:loadChapterModel(book, chapter_index)
        if not model then return nil, err end
        paragraph_index = math.max(1, #model.paragraphs)
        local length = paragraphLength(model, paragraph_index)
        -- 4096 characters is several Kindle pages in normal layouts, while still
        -- bounding the amount of shaping needed to recover the previous screen.
        char_index = math.max(1, length - 4096)
    elseif char_index > 1 then
        char_index = math.max(1, char_index - 4096)
    else
        paragraph_index = math.max(1, paragraph_index - 8)
        char_index = 1
    end
    return { chapter = chapter_index, paragraph = paragraph_index, char = char_index }
end

function Paginator:findPreviousPage(book, target_position, style)
    target_position = normalizePosition(book, target_position)
    if self:isChapterStart(book, target_position) then
        if target_position.chapter <= 1 then return nil, "已经是第一页" end
        -- Recover the actual last page using the same boundaries as forward
        -- reading. Starting at a trailing blank paragraph advances straight
        -- back into the current chapter and used to look like a no-op.
        local cursor = makePosition(book, target_position.chapter - 1, 1, 1)
        local previous
        while cursor.chapter < target_position.chapter do
            local page, err = self:makePage(book, cursor, style)
            if not page then return nil, err end
            if page.chapter_index >= target_position.chapter then break end
            previous = page
            if not Util.positionLess(cursor, page.next_position) then
                return nil, "上一章分页未能前进"
            end
            cursor = page.next_position
        end
        return previous, previous and nil or "上一章没有可显示的正文"
    end
    local cursor, start_err = previousSearchStart(book, target_position)
    if not cursor then return nil, start_err end

    local previous_page = nil
    -- Starting near the target removes the old O(all pages since chapter start)
    -- behavior. The window above normally needs fewer than ten iterations; 64 is
    -- a hard safety ceiling for unusual fonts, margins and paragraph structure.
    local safety = 0
    while safety < 64 do
        safety = safety + 1
        local page, err = self:makePage(book, cursor, style)
        if not page then return previous_page, err end
        if Util.positionEqual(page.next_position, target_position) then return page end
        if Util.positionLess(page.next_position, target_position) then
            previous_page = page
            cursor = page.next_position
        else
            return previous_page or page
        end
    end
    return previous_page, "向前分页超过局部安全限制"
end

return Paginator
