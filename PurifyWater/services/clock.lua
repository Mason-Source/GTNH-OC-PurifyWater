-- 时间唯一取用入口。
local computer = require("computer")

local clock = {}

function clock.uptime()
    return computer.uptime()
end

function clock.realTime()
    return computer.realTime()
end

function clock.cpuTime()
    return os.clock()
end

return clock
