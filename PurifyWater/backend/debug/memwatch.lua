--------------------------------------------------------------------------------
-- backend/debug/memwatch.lua
--------------------------------------------------------------------------------
-- 【职责】内存观测：地板/峰值采样、刷新新低时告警、痕迹留痕、退出摘要里那一小段文字
-- 【不做什么】不碰业务：不读机器、不改状态、不写业务数据、不进界面与调度
-- 【依赖】computer、shared/logs、backend/store/trace
-- 【被谁用】main.lua / backend/jobs（**都只在 --debug 下才 require 它**）
--
-- 仅 --debug 才装载本模块；日常运行不采样。
--------------------------------------------------------------------------------

local computer          = require("computer")
local logs              = require("shared.logs")
local trace             = require("backend.store.trace")

local memwatch          = {}

-- 地板 = 本次运行最低可用；峰值 = 总 - 地板（总固定，最低可用即最高占用）。
local memFloor, memPeak = nil, nil
-- 上次告警的地板
local memFloorWarned    = nil
-- 上次写痕迹时刻
local memTraceAt        = 0

--- 采一次内存，刷新地板与峰值（零垃圾：不写日志、不拼字符串）
-- 堆会顶到活数据约两倍才回收，可用在几十到几百 K 摆动；地板停住即健康。
-- @return number 本次"可用"（K）
-- @return number 本次"可用"（字节）
-- @return number 总（字节）
local function note()
    local free   = computer.freeMemory() or 0
    local total  = computer.totalMemory() or 0
    local floorK = math.floor(free / 1024)
    if not memFloor or floorK < memFloor then memFloor = floorK end
    memPeak = math.floor(total / 1024) - memFloor
    return floorK, free, total
end

--- T6 内存采样（1 秒）：只更新地板/峰值
-- 最占内存的瞬间是界面重画（几十毫秒），30 秒一采会漏峰；两个整数比较，不造垃圾。
function memwatch.sample()
    note()
end

--- 看护（T5 开头与退出前）：刷地板/峰值、新低告警、10 分钟留痕
-- OC 无 collectgarbage；靠少造垃圾、少留数据，回收由 event.pull 让出时自动跑。
-- @param elapsed number|nil 本次运行秒数（jobs.elapsed() 为唯一口径）
function memwatch.watch(elapsed)
    local floorK, _, total = note()

    logs.debug(string.format("内存：可用 %dK / 地板 %dK / 峰值 %dK / 总 %dK",
        floorK, memFloor, memPeak, math.floor(total / 1024)))

    -- 告警只在刷新新低时：低于总量 6% 且每降 16K 报一次；判地板（本拍可能采在高处）。
    if total > 0 and memFloor * 1024 < total * 0.06 then
        if not memFloorWarned or memFloor <= memFloorWarned - 16 then
            memFloorWarned = memFloor
            logs.warn(string.format("内存新低：可用 %dK / 总 %dK",
                memFloor, math.floor(total / 1024)))
        end
    end

    -- 留痕：地板低时每 10 分钟写一行（带峰值）；--debug 一路记。
    local now = computer.uptime()
    if (memFloor * 1024 < total * 0.3) or logs.isDebug() then
        if (now - memTraceAt) > 600 then
            memTraceAt = now
            trace.line(string.format("内存：峰值 %dK / 总 %dK（地板 %dK），本次运行 %d 分",
                memPeak, math.floor(total / 1024), memFloor,
                math.floor((elapsed or 0) / 60)))
        end
    end
end

--- 写启动两行痕迹（读数须在任何模块加载前取好）
-- @param bootFree number 引导阶段的"可用"（字节）
-- @param bootTotal number 引导阶段的"总"（字节）
function memwatch.traceBoot(bootFree, bootTotal)
    trace.line(string.format("内存基线：可用 %dK / 总 %dK（仅已加载引导模块，差值为 OpenOS shell）",
        math.floor((bootFree or 0) / 1024), math.floor((bootTotal or 0) / 1024)))

    -- 装载后读数含加载垃圾（GC 攒够才跑），勿当模块大小；
    -- 可用的是"基线"（OpenOS 地盘）与运行中的可用/峰值/地板。
    local free  = computer.freeMemory() or 0
    local total = computer.totalMemory() or 0
    trace.line(string.format("内存加载后：可用 %dK / 总 %dK（含加载期垃圾，略高于实际占用）",
        math.floor(free / 1024), math.floor(total / 1024)))
end

--- 退出摘要的内存段（未采样返回 nil）
-- @return string|nil 例如 `峰值 1892K / 总 2048K（可用 156K / 地板 156K）`
function memwatch.summary()
    if not memPeak then return nil end
    return string.format("峰值 %dK / 总 %dK（可用 %dK / 地板 %dK）",
        memPeak, math.floor((computer.totalMemory() or 0) / 1024),
        math.floor((computer.freeMemory() or 0) / 1024), memFloor)
end

return memwatch
