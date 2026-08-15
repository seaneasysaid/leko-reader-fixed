local logger_ok, logger = pcall(require, "logger")
if not logger_ok or type(logger) ~= "table" then logger = { err = function() end } end

local Diagnostics = {}

local function loadStorage()
    local ok, module = pcall(require, "Leko/Storage")
    return ok and type(module) == "table" and module or nil
end

local function loadUtil()
    local ok, module = pcall(require, "Leko/Util")
    return ok and type(module) == "table" and module or nil
end

function Diagnostics:getPath()
    local Storage = loadStorage()
    local dir = Storage and type(Storage.getLogsDir) == "function" and Storage:getLogsDir() or "/tmp"
    return tostring(dir):gsub("/+$", "") .. "/last-error.log"
end

local function fallbackWrite(path, body)
    local file = io.open(path, "wb")
    if not file then return false end
    local wrote = file:write(body)
    if wrote then file:flush() end
    file:close()
    return wrote ~= nil
end

function Diagnostics:record(label, detail)
    label = tostring(label or "operation")
    detail = tostring(detail or "unknown error")
    logger.err("Leko", label, detail)
    local path = self:getPath()
    local body = os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. label .. "\n\n" .. detail .. "\n"
    local Util = loadUtil()
    local ok
    if Util then
        local dir = path:match("^(.*)/[^/]+$")
        if dir and type(Util.mkdirp) == "function" then pcall(Util.mkdirp, dir) end
        if type(Util.writeFile) == "function" then ok = Util.writeFile(path, body, true) end
    end
    if ok ~= true then ok = fallbackWrite(path, body) end
    return ok and path or nil
end

function Diagnostics:readLast()
    local path = self:getPath()
    local Util = loadUtil()
    local data
    if Util and type(Util.readFile) == "function" then data = Util.readFile(path, true) end
    if not data then
        local file = io.open(path, "rb")
        if file then data = file:read("*a"); file:close() end
    end
    if not data or data == "" then return nil, path end
    return data, path
end

return Diagnostics
