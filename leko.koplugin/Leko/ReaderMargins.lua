local ReaderMargins = {
    values = { 12, 20, 28, 36, 48 },
    labels = { "最窄", "窄", "中", "宽", "最宽" },
}

function ReaderMargins:index(value)
    for index, preset in ipairs(self.values) do
        if tonumber(value) == preset then return index end
    end
end

-- Keep stored preset values compatible while ensuring wider choices really
-- lose at least one fullwidth column. A fixed pixel step can otherwise round
-- two neighboring choices to the same text width at larger font sizes.
function ReaderMargins:columns(index, screen_width, cell_width, scale)
    local previous = math.floor(screen_width / cell_width) + 1
    for current = 1, index do
        local available = screen_width - 2 * scale(self.values[current])
        local columns = math.floor(math.max(0, available) / cell_width)
        previous = math.max(1, math.min(columns, previous - 1))
    end
    return previous
end

return ReaderMargins
