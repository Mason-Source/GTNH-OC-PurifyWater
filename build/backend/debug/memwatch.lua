local computer          = require("computer")
local logs              = require("shared.logs")
local trace             = require("backend.store.trace")
local memwatch          = {}
local memFloor, memPeak = nil, nil
local memFloorWarned    = nil
local memTraceAt        = 0
local function note()
    local free   = computer.freeMemory() or 0
    local total  = computer.totalMemory() or 0
    local floorK = math.floor(free / 1024)
    if not memFloor or floorK < memFloor then memFloor = floorK end
    memPeak = math.floor(total / 1024) - memFloor
    return floorK, free, total
end
function memwatch.sample()
    note()
end
function memwatch.watch(elapsed)
    local floorK, _, total = note()
    logs.debug(string.format("[调试] 内存：可用 %dK / 地板 %dK / 峰值 %dK / 总 %dK",
        floorK, memFloor, memPeak, math.floor(total / 1024)))
    if total > 0 and memFloor * 1024 < total * 0.06 then
        if not memFloorWarned or memFloor <= memFloorWarned - 16 then
            memFloorWarned = memFloor
            logs.warn(string.format("内存新低：可用 %dK / 总 %dK —— 低位在往下走，离崩不远",
                memFloor, math.floor(total / 1024)))
        end
    end
    local now = computer.uptime()
    if (memFloor * 1024 < total * 0.3) or logs.isDebug() then
        if (now - memTraceAt) > 600 then
            memTraceAt = now
            trace.line(string.format("内存：峰值 %dK / 总 %dK（地板 %dK），本次已跑 %d 分",
                memPeak, math.floor(total / 1024), memFloor,
                math.floor((elapsed or 0) / 60)))
        end
    end
end
function memwatch.traceBoot(bootFree, bootTotal)
    trace.line(string.format("内存基线：可用 %dK / 总 %dK（此刻只装了引导模块，差额就是 OpenOS shell）",
        math.floor((bootFree or 0) / 1024), math.floor((bootTotal or 0) / 1024)))
    local free  = computer.freeMemory() or 0
    local total = computer.totalMemory() or 0
    trace.line(string.format("内存装载后：可用 %dK / 总 %dK（含加载垃圾，比实际占用偏大）",
        math.floor(free / 1024), math.floor(total / 1024)))
end
function memwatch.summary()
    if not memPeak then return nil end
    return string.format("峰值 %dK / 总 %dK（可用 %dK / 地板 %dK）",
        memPeak, math.floor((computer.totalMemory() or 0) / 1024),
        math.floor((computer.freeMemory() or 0) / 1024), memFloor)
end
return memwatch
