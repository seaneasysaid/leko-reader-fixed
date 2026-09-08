-- Reuse is deliberately narrower than rule execution. Unknown/stateful rules
-- keep the full parser. No source names, domains or catalogue field names are
-- used to decide whether a chapter is reusable.
local json = require("rapidjson")
local Digest = require("Leko/Digest")
local QuickJS = require("Leko/QuickJS")
local Reuse = {}

local function field(rule)
    return rule == nil or rule == "" or (type(rule) == "string"
        and rule:match("^%$[%.%[]") and not rule:find("[@{}\r\n]")
        and not rule:find("%(") and not rule:find("%s"))
end

local builtins = { ["if"]=true, ["catch"]=true, String=true, Number=true,
    ["JSON.stringify"]=true, ["JSON.parse"]=true,
    ["java.base64Encode"]=true, ["java.base64Decode"]=true,
    ["java.urlEncode"]=true, ["java.urlDecode"]=true }
local reads = { ["java.get"]=true, ["java.getCookie"]=true,
    ["source.getVariable"]=true }

local function surface(text)
    local out, i = {}, 1
    local scan
    scan = function(stop)
        local depth = 0
        while i <= #text do
            local c, n = text:sub(i,i), text:sub(i+1,i+1)
            if stop and c == "}" and depth == 0 then out[#out+1]=" "; i=i+1; return end
            if c == "'" or c == '"' then
                local quote=c; out[#out+1]=" "; i=i+1
                while i <= #text do
                    c=text:sub(i,i); out[#out+1]=" "; i=i+1
                    if c == "\\" then out[#out+1]=" "; i=i+1
                    elseif c == quote then break end
                end
            elseif c == "`" then
                out[#out+1]=" "; i=i+1
                while i <= #text do
                    c=text:sub(i,i); n=text:sub(i+1,i+1)
                    if c == "`" then out[#out+1]=" "; i=i+1; break
                    elseif c == "\\" then out[#out+1]="  "; i=i+2
                    elseif c == "$" and n == "{" then out[#out+1]="  "; i=i+2; scan(true)
                    else out[#out+1]=" "; i=i+1 end
                end
            elseif c == "/" and n == "/" then
                while i <= #text and text:sub(i,i) ~= "\n" do out[#out+1]=" "; i=i+1 end
            elseif c == "/" and n == "*" then
                out[#out+1]="  "; i=i+2
                while i <= #text and text:sub(i,i+1) ~= "*/" do out[#out+1]=" "; i=i+1 end
                out[#out+1]="  "; i=i+2
            else
                if c == "{" then depth=depth+1 elseif c == "}" then depth=depth-1 end
                out[#out+1]=c; i=i+1
            end
        end
    end
    scan(false)
    return table.concat(out)
end

-- This is an optimization gate, not a JavaScript validator. Accept only a
-- small read-only builder shape; uncertain syntax is handled by the normal
-- interpreter. Inspect raw template text too, so ${...} is never hidden.
local function readOnly(code, library, visiting, captures, top)
    if #code > 12000 then return false end
    for _, token in ipairs({ "++", "--", "=>", "eval", "Date",
        "Math", "random", "fetch", "ajax", "connect", "post(", "put(",
        "setVariable", "setCookie", "removeCookie", "Object.", "Reflect.",
        "globalThis", "prototype", "constructor", "while", "for(", "for (",
        "delete ", "new ", "throw ", "@put", "@get", "{{" }) do
        if code:find(token, 1, true) then return false end
    end
    local syntax = surface(code)
    if syntax:find("[\128-\255]") then return false end
    if syntax:find("[%w_%]]%s*%.%s*[%w_]+%s*=[^=]")
            or syntax:find("%]%s*=[^=]") or syntax:find("%]%s*%(")
            or syntax:find("[%+%-%*/%%&|%^]=") then return false end
    local locals = {}
    for declaration in syntax:gmatch("[lc][eo][tns]*%s+([^;\n]+)") do
        local name = declaration:match("^([%w_]+)")
        if name then locals[name] = true end
        local destructure = declaration:match("^(%b{})")
        if destructure then for key in destructure:gmatch("[%a_][%w_]*") do locals[key]=true end end
    end
    -- Parameters are local too. Recursive helpers below retain their header.
    for params in code:gmatch("function%s+[%w_]+%s*(%b())") do
        for name in params:gmatch("[%a_][%w_]*") do locals[name] = true end
    end
    for name in syntax:gmatch("([%a_][%w_]*)%s*=[^=>=]") do
        if not locals[name] then return false end
    end
    local calls, cursor = {}, 1
    while true do
        local _, last, callee = syntax:find("([%a_][%w_%.]*)%s*%(", cursor)
        if not last then break end
        local args = code:sub(last):match("^%b()")
        if not args then return false end
        calls[#calls+1] = {callee, args}
        cursor = last + 1
    end
    for _, call in ipairs(calls) do
        local callee, args = call[1], call[2]
        local name = callee:gsub("^this%.", "")
        local method = name:match("%.([%w_]+)$")
        if builtins[name] or method == "includes" or method == "replace"
                or name == "includes" or name == "replace" then
            -- String operations only; callback/function syntax is rejected.
            local receiver = name:match("^([%w_]+)%.")
            if (method == "includes" or method == "replace") and not locals[receiver] then return false end
        elseif reads[name] then
            if top then
                local rest = args:gsub("'[^']*'", ""):gsub('"[^"]*"', "")
                if rest:find("[^%s%(%)%d,%-]") then return false end
                captures[name .. args] = true
            end
        elseif name == code:match("^%s*function%s+([%w_]+)") then
            -- Function declaration, not a call.
        else
            if name:find("%.") or visiting[name] then return false end
            local body = library:match("function%s+" .. name .. "%s*%b()%s*(%b{})")
            local params = library:match("function%s+" .. name .. "%s*(%b())%s*{")
            if not body then return false end
            visiting[name] = true
            local ok = readOnly("function " .. name .. params .. body, library, visiting, captures, false)
            visiting[name] = nil
            if not ok then return false end
            locals[name] = true
            if top then
                -- Evaluate helper reads once per page to include the actual
                -- configuration/global values in the dependency signature.
                if args ~= "()" then return false end
                captures[callee .. args] = true
            end
        end
    end
    if top then
        for _, reserved in ipairs({"java", "JSON", "String", "Number", "result"}) do
            if locals[reserved] then return false end
        end
        local words = syntax:gsub("%.[%a_][%w_]*", "")
            :gsub("([,{]%s*)[%a_][%w_]*%s*:", "%1")
        local known = { ["let"]=true, ["const"]=true, ["var"]=true, ["if"]=true,
            ["else"]=true, ["return"]=true, ["true"]=true, ["false"]=true,
            ["null"]=true, undefined=true, result=true, java=true, JSON=true,
            String=true, Number=true }
        for word in words:gmatch("[%a_][%w_]*") do
            if not known[word] and not locals[word] then return false end
        end
    end
    return true
end

function Reuse:prepare(source, rules, env, base)
    for key, rule in pairs(rules or {}) do
        if key ~= "chapterList" and key ~= "chapter_list" and key ~= "list"
                and key ~= "chapterUrl" and key ~= "url" and key ~= "href"
                and key ~= "preUpdateJs" and key ~= "pre_update_js"
                and not field(rule) then return nil end
    end
    local url = rules.chapterUrl or rules.url or rules.href
    local captures = {}
    local raw = source.raw or source
    local library = tostring(raw.jsLib or source.js_lib or "") .. "\n"
        .. tostring(raw.loginUrl or source.login_url or "")
    if not field(url) then
        local script = QuickJS:unwrap(url)
        -- Cache only self-contained data descriptors, never expiring HTTP
        -- signatures. Other scripts retain their existing lazy/full behavior.
        if not script:find("data:", 1, true)
                or not readOnly(script, library, {}, captures, true) then return nil end
    end
    local values = {}
    for call in pairs(captures) do
        local value, err = QuickJS:eval(call, env)
        if err then return nil end
        values[call] = value
    end
    local ok, encoded = pcall(json.encode, { version=1, rules=rules, library=library,
        source=source.id, base=base, reads=values }, {sort_keys=true})
    if not ok then return nil end
    return Digest:sha256(encoded)
end

function Reuse:key(node, signature)
    if not signature or type(node) ~= "table" then return nil end
    local ok, encoded = pcall(json.encode, node, {sort_keys=true})
    if not ok then return nil end
    return Digest:sha256(signature .. "\n" .. encoded)
end

function Reuse:canStore(rule, url)
    return field(rule) or tostring(url or ""):match("^data:") ~= nil
end

function Reuse:itemKey(node, signature)
    if not signature or type(node) ~= "table" then return nil end
    local id = node.item_id or node.chapter_id or node.cid or node.id
    if type(id) ~= "string" and type(id) ~= "number" then return nil end
    if tostring(id) == "" then return nil end
    return self:key({id=id, source=node.source, tab=node.tab}, signature)
end

function Reuse:index(chapters)
    local result = { items={}, count=#(chapters or {}) }
    for _, chapter in ipairs(chapters or {}) do
        if chapter._toc_reuse_key then result[chapter._toc_reuse_key] = chapter end
        local key = chapter._toc_item_key
        if key then
            result.items[key] = result.items[key] == nil and chapter or false
        end
    end
    return result
end

return Reuse
