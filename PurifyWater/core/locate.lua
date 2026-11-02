--------------------------------------------------------------------------------
-- PurifyWater/core/locate.lua
--
-- 定位：应用目录定位与 require 路径初始化。
-- 功能：根据显式参数、源码位置和工作目录寻找包含 core/bootstrap.lua 的应用根目录。
-- 边界：只处理路径，不 require 任何业务模块，也不访问硬件组件。
--------------------------------------------------------------------------------

local locate = {}

--- 某目录是否是应用根目录
---@param dir string|nil 待检查目录。
---@return boolean 是否为应用根目录。
local function isAppDir(dir)
    if type(dir) ~= "string" or dir == "" then return false end
    local ok, fs = pcall(require, "filesystem")
    if not ok or not fs then return false end
    return fs.exists(dir .. "/core/bootstrap.lua") == true
end

--- 定位应用根目录
---@param hint string|nil 显式指定（命令行第一个参数 / 调用方已知）
---@param selfSource string|nil 自身源码路径（`(debug.getinfo(1,"S").source):gsub("^@","")`）
---@return string 应用根目录（找不到时返回 ""）
function locate.appDir(hint, selfSource)
    if isAppDir(hint) then
        ---@cast hint string
        return hint
    end

    local selfDir = type(selfSource) == "string" and selfSource:match("^(.*)[/\\][^/\\]*$") or nil
    local candidates = {}
    if selfDir then
        table.insert(candidates, selfDir)
    end
    pcall(function()
        local shell = require("shell")
        local cwd = shell.getWorkingDirectory()
        table.insert(candidates, cwd)
        table.insert(candidates, cwd .. "/PurifyWater")
        table.insert(candidates, cwd .. "/..")
        table.insert(candidates, cwd .. "/../PurifyWater")
    end)

    for _, dir in ipairs(candidates) do
        if isAppDir(dir) then return dir end
    end
    return ""
end

--- 注入 require 路径：`package.path = appDir .. "/?.lua;..."` 的规范写法
---@param appDir string
---@return string 注入后的 package.path
function locate.injectPath(appDir)
    package.path = appDir .. "/?.lua;" .. appDir .. "/?/init.lua;" .. package.path
    return package.path
end

return locate
