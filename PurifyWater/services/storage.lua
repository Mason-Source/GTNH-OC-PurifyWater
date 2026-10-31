local filesystem = require("filesystem")

local storage = {}
local ROOT = "."

function storage.setRoot(dir)
    ROOT = tostring(dir or ".")
end

function storage.root()
    return ROOT
end

local function pathOf(name)
    name = tostring(name or "")
    if name:match("^[/\\]") or name:match("^%a:[/\\]") then return name end
    return ROOT .. "/" .. name
end

local function write(path, lines, mode)
    local full = pathOf(path)
    local dir = full:match("^(.*)[/\\][^/\\]*$")
    if dir and not filesystem.exists(dir) then
        pcall(filesystem.makeDirectory, dir)
    end

    local file, err = io.open(full, mode)
    if not file then return false, tostring(err) end
    for _, line in ipairs(lines or {}) do
        file:write(tostring(line), "\n")
    end
    file:close()
    return true, full
end

function storage.append(path, lines)
    return write(path, lines, "a")
end

function storage.replace(path, lines)
    return write(path, lines, "w")
end

function storage.readText(path)
    local file = io.open(pathOf(path), "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

function storage.writeText(path, text)
    local full = pathOf(path)
    local dir = full:match("^(.*)[/\\][^/\\]*$")
    if dir and not filesystem.exists(dir) then
        pcall(filesystem.makeDirectory, dir)
    end

    local file, err = io.open(full, "w")
    if not file then return false, tostring(err) end
    file:write(tostring(text or ""))
    file:close()
    return true, full
end

function storage.readLines(path)
    local file = io.open(pathOf(path), "r")
    if not file then return {} end
    local lines = {}
    for line in file:lines() do
        if line ~= "" then lines[#lines + 1] = line end
    end
    file:close()
    return lines
end

function storage.exists(path)
    return filesystem.exists(pathOf(path)) == true
end

function storage.list(prefix)
    local out = {}
    local dir, namePrefix = prefix:match("^(.*/)([^/]+)$")
    local result = { pcall(filesystem.list, pathOf(dir)) }
    if not result[1] or not result[2] then return out end

    if type(result[2]) == "table" then
        if #result[2] > 0 then
            for _, name in ipairs(result[2]) do
                if name:sub(1, #namePrefix) == namePrefix then out[#out + 1] = dir .. name end
            end
        else
            for name in pairs(result[2]) do
                if name:sub(1, #namePrefix) == namePrefix then out[#out + 1] = dir .. name end
            end
        end
    else
        for name in result[2], result[3], result[4] do
            if name:sub(1, #namePrefix) == namePrefix then out[#out + 1] = dir .. name end
        end
    end
    return out
end

function storage.remove(path)
    local ok, result = pcall(filesystem.remove, pathOf(path))
    return ok and result == true
end

return storage
