local locate = {}
local function isAppDir(dir)
    if type(dir) ~= "string" or dir == "" then return false end
    local ok, fs = pcall(require, "filesystem")
    if not ok or not fs then return false end
    return fs.exists(dir .. "/core/bootstrap.lua") == true
end
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
function locate.injectPath(appDir)
    package.path = appDir .. "/?.lua;" .. appDir .. "/?/init.lua;" .. package.path
    return package.path
end
return locate
