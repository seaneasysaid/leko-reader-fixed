local ReaderMargins = {
    -- 排版滑块的刻度：8~48，步长 2。
    values = {},
    -- 旧全屏菜单仍用五档标签；这些值也保留原来的「每档至少少一列」算法。
    presets = { 12, 20, 28, 36, 48 },
    labels = { "最窄", "窄", "中", "宽", "最宽" },
}

for value = 8, 48, 2 do
    ReaderMargins.values[#ReaderMargins.values + 1] = value
end

function ReaderMargins:index(value)
    for index, preset in ipairs(self.values) do
        if tonumber(value) == preset then return index end
    end
end

local function legacyIndex(value)
    for index, preset in ipairs(ReaderMargins.presets) do
        if tonumber(value) == preset then return index end
    end
end

-- 旧五档：保持原来的每档至少少一列，避免老存档版面突然变化。
local function legacyColumns(index, screen_width, cell_width, scale)
    local previous = math.floor(screen_width / cell_width) + 1
    for current = 1, index do
        local available = screen_width - 2 * scale(ReaderMargins.presets[current])
        local columns = math.floor(math.max(0, available) / cell_width)
        previous = math.max(1, math.min(columns, previous - 1))
    end
    return previous
end

local function directColumns(value, screen_width, cell_width, scale)
    local available = screen_width - 2 * scale(value)
    return math.max(1, math.floor(math.max(0, available) / cell_width))
end

-- 新细刻度：从 8 开始逐档取「实际可用列数」，并保证列数只减不增。
-- 旧五档仍把列数压到原算法的值，这样 28→30 这种相邻档位不会出现
-- 「边距更大、正文反而更宽」的倒挂；2px 同列时正文仍会随边距整体内缩。
function ReaderMargins:columns(value, screen_width, cell_width, scale)
    value = tonumber(value) or 28
    local columns
    for current = 8, 48, 2 do
        if current > value then break end
        local next_columns = directColumns(current, screen_width, cell_width, scale)
        if columns then next_columns = math.min(next_columns, columns) end
        local old = legacyIndex(current)
        if old then
            next_columns = math.min(next_columns,
                legacyColumns(old, screen_width, cell_width, scale))
        end
        columns = next_columns
    end
    if not columns then columns = directColumns(value, screen_width, cell_width, scale) end
    -- 非网格值（老配置里的 6/14 等）也要被前一档封顶。
    if value % 2 ~= 0 or value < 8 or value > 48 then
        columns = math.min(columns, directColumns(value, screen_width, cell_width, scale))
    end
    return columns
end

return ReaderMargins
