--------------------------------------------------------------------------------
-- PurifyWater/services/storage.lua
--
-- 定位：应用根目录下的文件系统适配器。
-- 功能：封装目录创建、文本/行读写、追加、替换、列表和删除操作。
-- 边界：不解析文件内容，不决定文件名或数据格式。
--------------------------------------------------------------------------------

local filesystem = require("filesystem")

local storage = {}
local ROOT = "."

--- 设置相对路径解析所使用的工作根目录。
function storage.setRoot(dir)
    ROOT = tostring(dir or ".")
end

--- 返回当前工作根目录。
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

--- 向文本文件追加若干行，必要时创建父目录。
function storage.append(path, lines)
    return write(path, lines, "a")
end

--- 用若干行覆盖文本文件，必要时创建父目录。
function storage.replace(path, lines)
    return write(path, lines, "w")
end

--- 读取完整文本；文件不存在时返回 nil。
function storage.readText(path)
    local file = io.open(pathOf(path), "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

--- 写入完整文本，必要时创建父目录。
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

--- 读取非空文本行数组。
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

--- 判断路径是否存在。
function storage.exists(path)
    return filesystem.exists(pathOf(path)) == true
end

--- 列出指定前缀匹配的文件名。
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

--- 删除指定文件并返回操作结果。
function storage.remove(path)
    local ok, result = pcall(filesystem.remove, pathOf(path))
    return ok and result == true
end

return storage
