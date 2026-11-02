--------------------------------------------------------------------------------
-- PurifyWater/services/clock.lua
--
-- 定位：运行时间的唯一取用入口。
-- 功能：统一提供单调 uptime、墙钟 realTime 和 CPU 时间。
-- 边界：只读时间；其他模块不得绕过本模块直接调用 computer 或 os.clock。
--------------------------------------------------------------------------------

local computer = require("computer")

local clock = {}

--- 返回 OC 单调运行时间（秒）。
function clock.uptime()
    return computer.uptime()
end

--- 返回 OC 墙钟时间（秒）。
function clock.realTime()
    return computer.realTime()
end

--- 返回当前 Lua 进程 CPU 时间（秒）。
function clock.cpuTime()
    return os.clock()
end

return clock
