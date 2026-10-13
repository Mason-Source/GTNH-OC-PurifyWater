--------------------------------------------------------------------------------
-- backend/store/files.lua
--------------------------------------------------------------------------------
-- 【职责】文件读写原语：整读/按行读/原子写/存在性/删除
-- 【不做什么】不识业务格式（shared/models）
-- 【依赖】filesystem、io
-- 【被谁用】backend/store/*（唯一写盘层）
--
-- 坑：filesystem.open() 的句柄不支持 f:read("*a")，整读用 io.open。
-- 原子写：先写 .tmp 再改名。
--------------------------------------------------------------------------------

local filesystem = require("filesystem")

local files = {}

-- 数据根目录：boot 时注入应用目录
local ROOT = "."

--- 设置数据根目录（入口调用）
-- @param dir string
function files.setRoot(dir)
    ROOT = tostring(dir or ".")
end

--- 当前数据根目录（= 应用目录）
-- @return string
function files.root()
    return ROOT
end

--- 解析实际路径：/ 开头为绝对，否则相对应用根目录。
-- @param name string
-- @return string
function files.path(name)
    local s = tostring(name or "")
    if s:sub(1, 1) == "/" then return s end
    return ROOT .. "/" .. s
end

--- 文件是否存在
-- @param path string
-- @return boolean
function files.exists(path)
    local ok, v = pcall(filesystem.exists, path)
    return ok and v == true
end

--- 整读文件（失败返回 nil，不抛错）
-- @param path string
-- @return string|nil
function files.read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local ok, text = pcall(function() return f:read("*a") end)
    f:close()
    if not ok then return nil end
    return text
end

--- 按行读（去空行，保留 # 注释行）
-- @param path string
-- @return table 行数组（文件不存在时为空表）
function files.readLines(path)
    local text = files.read(path)
    if not text then return {} end
    local out = {}
    for line in text:gmatch("[^\r\n]+") do
        if line:gsub("%s", "") ~= "" then out[#out + 1] = line end
    end
    return out
end

--- 确保目录存在（幂等）
-- @param dir string 完整路径
-- @return boolean
function files.ensureDir(dir)
    if dir == nil or dir == "" or dir == "." then return true end
    if files.exists(dir) then return true end
    pcall(filesystem.makeDirectory, dir)
    return files.exists(dir)
end

--- 原子写文本：临时文件 -> 改名覆盖；目标目录不存在则建。
-- @param path string
-- @param text string
-- @return boolean 是否成功
-- @return string|nil 失败原因
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

--- 原子写行数组
-- @param path string
-- @param lines table 行数组（自动补换行）
-- @return boolean 是否成功
-- @return string|nil 失败原因
function files.writeLines(path, lines)
    local out = {}
    for _, line in ipairs(lines) do out[#out + 1] = tostring(line) end
    return files.write(path, table.concat(out, "\n") .. "\n")
end

return files
