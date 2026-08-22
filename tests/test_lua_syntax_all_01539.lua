local plugin_root = assert(arg[1]):gsub("\\", "/")
local checked = 0
-- The lab's existing filesystem adapter intentionally exposes only the
-- subset needed by production code on some Windows hosts. Use its already
-- installed ripgrep binary to enumerate the complete candidate tree, then
-- compile each file in the same Lua process.
local command = 'rg --files -g "*.lua" "' .. plugin_root:gsub('"', '\\"') .. '"'
local pipe = assert(io.popen(command))
for listed in pipe:lines() do
    local path = tostring(listed):gsub("\\", "/")
    if not path:match("^%a:/") then path = plugin_root .. "/" .. path end
    local chunk, err = loadfile(path)
    if not chunk then error("Lua syntax failed: " .. path .. "\n" .. tostring(err), 2) end
    checked = checked + 1
end
pipe:close()
assert(checked > 0, "no Lua files were found")
print("all packaged Lua syntax checks: " .. tostring(checked) .. " files OK")
