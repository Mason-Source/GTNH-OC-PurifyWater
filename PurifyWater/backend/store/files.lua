--------------------------------------------------------------------------------
-- backend/store/files.lua
--------------------------------------------------------------------------------
-- 【职责】文件读写原语：整读、按行读、**原子写**、存在性、删除
-- 【不做什么】不认识任何业务格式（行 -> 表由 shared/models 做）
-- 【依赖】filesystem（存在性/删除）、io（读写）
-- 【被谁用】backend/store/*（唯一允许写盘的一层）
--
-- 【坑】`filesystem.open()` 拿到的句柄**不支持 `f:read("*a")`**：整读一律用 `io.open`，
--   filesystem 只用来 exists / remove / size。
-- 【原子写】先写 `<path>.tmp` 再改名：中途掉电/退出不会留下半截文件
--   （并行记录被写坏就等于记录全失效）。
--------------------------------------------------------------------------------

local filesystem = require("filesystem")

local files = {}

-- 数据文件根目录：boot 时注入应用目录，配置里的相对名都相对它解析
local ROOT = "."

--- 设置数据文件根目录（入口在 boot 时调 `files.setRoot(appDir)`）
-- @param dir string
function files.setRoot(dir)
    ROOT = tostring(dir or ".")
end

--- 把配置里的文件名解析成实际路径
-- 【规则】以 "/" 开头的当绝对路径，否则相对应用根目录
--   （应用目录一定可写，不赌文件系统根目录）
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

--- 按行读（去掉空行；保留 # 注释行，由解析层决定是否忽略）
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

--- 确保目录存在（幂等；不存在就建）
-- 数据收在 data/ 子目录里，而 io.open 不会自动建目录。
-- @param dir string 完整路径
-- @return boolean
function files.ensureDir(dir)
    if dir == nil or dir == "" or dir == "." then return true end
    if files.exists(dir) then return true end
    pcall(filesystem.makeDirectory, dir)
    return files.exists(dir)
end

--- 原子写文本：写临时文件 -> 改名覆盖
-- 【原子】中途掉电/退出不会留下半截文件（并行记录被写坏 = 记录全失效）。
-- 【顺便建目录】目标在 data/ 下时，第一次写会自动把目录建出来。
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

--- 删除文件（不存在也算成功）
-- @param path string
-- @return boolean
function files.remove(path)
    return pcall(filesystem.remove, path) ~= nil
end

return files
