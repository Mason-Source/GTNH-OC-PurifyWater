local filesystem = require("filesystem")
local files = {}
local ROOT = "."
function files.setRoot(dir)
    ROOT = tostring(dir or ".")
end
function files.path(name)
    local s = tostring(name or "")
    if s:sub(1, 1) == "/" then return s end
    return ROOT .. "/" .. s
end
function files.exists(path)
    local ok, v = pcall(filesystem.exists, path)
    return ok and v == true
end
function files.read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local ok, text = pcall(function() return f:read("*a") end)
    f:close()
    if not ok then return nil end
    return text
end
function files.readLines(path)
    local text = files.read(path)
    if not text then return {} end
    local out = {}
    for line in text:gmatch("[^\r\n]+") do
        if line:gsub("%s", "") ~= "" then out[#out + 1] = line end
    end
    return out
end
function files.ensureDir(dir)
    if dir == nil or dir == "" or dir == "." then return true end
    if files.exists(dir) then return true end
    pcall(filesystem.makeDirectory, dir)
    return files.exists(dir)
end
function files.write(path, text)
    local dir = path:match("^(.*)[/\\][^/\\]*$")
    if dir then files.ensureDir(dir) end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then return false, tostring(err) end
    f:write(tostring(text or ""))
    f:close()
    local ok, renameErr = pcall(function()
        if filesystem.exists(path) then pcall(filesystem.remove, path) end
        pcall(filesystem.rename, tmp, path)
    end)
    if not ok then return false, tostring(renameErr) end
    return true
end
function files.writeLines(path, lines)
    local out = {}
    for _, line in ipairs(lines) do out[#out + 1] = tostring(line) end
    return files.write(path, table.concat(out, "\n") .. "\n")
end
function files.remove(path)
    return pcall(filesystem.remove, path) ~= nil
end
return files
