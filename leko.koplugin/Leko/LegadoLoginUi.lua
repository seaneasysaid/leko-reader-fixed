-- Minimal, data-only parser for Legado's standard loginUi row contract.
-- It never evaluates loginUrl, jsLib, or button code while configuration is
-- opened; source-owned code is evaluated only after the user invokes a button.
local rapidjson = require("rapidjson")

local LoginUi = { max_bytes = 128 * 1024 }

local function text(value) return tostring(value == nil and "" or value) end

local function normalizeLooseJson(value)
    local output, index, quote, escaped = {}, 1, nil, false
    while index <= #value do
        local char = value:sub(index, index)
        if not quote then
            if char == "'" then quote = "'"; output[#output + 1] = '"'
            elseif char == '"' then quote = '"'; output[#output + 1] = char
            else output[#output + 1] = char end
        elseif escaped then
            output[#output + 1] = quote == "'" and char == '"' and '\\"' or char
            escaped = false
        elseif char == "\\" then output[#output + 1] = char; escaped = true
        elseif char == quote then
            local closing_quote = quote
            quote = nil
            output[#output + 1] = closing_quote == "'" and '"' or char
        elseif char == '"' and quote == "'" then output[#output + 1] = '\\"'
        else output[#output + 1] = char end
        index = index + 1
    end
    local normalized = table.concat(output)
    normalized = normalized:gsub("([,{]%s*)([%a_$][%w_$%-]*)%s*:", '%1"%2":')
    return normalized:gsub(",%s*([}%]])", "%1")
end

local function decode(value)
    if type(value) == "table" then return value end
    local ok, result = pcall(rapidjson.decode, text(value))
    if ok and type(result) == "table" then return result end
    ok, result = pcall(rapidjson.decode, normalizeLooseJson(text(value)))
    return ok and type(result) == "table" and result or nil
end

function LoginUi.parse(value, limit)
    if type(value) ~= "table" then
        value = text(value)
        if value == "" or #value > (tonumber(limit) or LoginUi.max_bytes) then return nil end
    end
    local decoded = decode(value)
    if type(decoded) ~= "table" then return nil end
    local model, seen = { rows = {}, fields = {}, actions = {} }, {}
    for index, item in ipairs(decoded) do
        if type(item) == "table" and text(item.name) ~= "" then
            local kind = text(item.type == nil and "text" or item.type):lower()
            local row = { index = index, name = text(item.name), type = kind, action = text(item.action) }
            model.rows[#model.rows + 1] = row
            if (kind == "text" or kind == "password") and not seen[row.name] then
                seen[row.name] = true
                model.fields[#model.fields + 1] = row
            elseif kind == "button" then
                model.actions[#model.actions + 1] = row
            end
        end
    end
    return #model.rows > 0 and model or nil
end

return LoginUi
