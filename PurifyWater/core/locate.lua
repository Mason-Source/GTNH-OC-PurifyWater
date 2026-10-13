--------------------------------------------------------------------------------
-- core/locate.lua
--------------------------------------------------------------------------------
-- 【职责】定位应用根目录（含 core/ 的目录）
-- 【不做什么】不 require 工程模块
-- 【依赖】filesystem / shell（可选）
-- 【被谁用】main.lua、monitor.lua
--
-- 判据：含 core/bootstrap.lua 的目录。
-- 候选：显式传入、自身路径、工作目录/父目录/父目录下 PurifyWater
--------------------------------------------------------------------------------

local locate = {}

--- 某目录是否是应用根目录
-- @param dir string
-- @return boolean
local function isAppDir(dir)
    if type(dir) ~= "string" or dir == "" then return false end
    local ok, fs = pcall(require, "filesystem")
    if not ok or not fs then return false end
    return fs.exists(dir .. "/core/bootstrap.lua") == true
end

--- 定位应用根目录
-- @param hint string|nil 显式指定（命令行第一个参数 / 调用方已知）
-- @param selfSource string|nil 自身源码路径（`(debug.getinfo(1,"S").source):gsub("^@","")`）
-- @return string 应用根目录（找不到时返回 ""）
function locate.appDir(hint, selfSource)
    if isAppDir(hint) then return hint end

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
-- @param appDir string
-- @return string 注入后的 package.path
function locate.injectPath(appDir)
    package.path = appDir .. "/?.lua;" .. appDir .. "/?/init.lua;" .. package.path
    return package.path
end

return locate
