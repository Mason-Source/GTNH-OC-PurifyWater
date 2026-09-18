local event      = require("event")
local computer   = require("computer")
local CONFIG     = require("shared.config")
local logs       = require("shared.logs")
local utils      = require("shared.utils")
local scheduler  = require("core.scheduler")
local runtime    = {}
local quitting   = false
local quitReason = nil
function runtime.quit(reason)
    if quitting then return false end
    quitting   = true
    quitReason = reason or "程序退出"
    return true
end
function runtime.quitReason() return quitReason end
function runtime.discardStaleInterrupts()
    local dropped = 0
    for _ = 1, 20 do
        local ev = { event.pull(0) }
        if ev[1] == nil then break end
        if ev[1] == "interrupted" then
            dropped = dropped + 1
        else
            scheduler.emit(ev[1], ev)
        end
    end
    if dropped > 0 then
        logs.debug(string.format("[调试] 忽略启动瞬间的 %d 个 interrupted（上一个进程的残留）", dropped))
    end
    return dropped
end
local function clampWait(wait)
    local min = CONFIG.LOOP_MIN_IDLE or 0.05
    local max = CONFIG.LOOP_MAX_IDLE or 1.0
    if type(wait) ~= "number" or wait ~= wait then return max end
    if wait < min then return min end
    if wait > max then return max end
    return wait
end
function runtime.frame(onFrame)
    local now  = computer.uptime()
    local wait = clampWait(scheduler.secondsUntilDue(now))
    local ev   = { event.pull(wait) }
    if ev[1] ~= nil then
        scheduler.emit(ev[1], ev)
    end
    if quitting then return true end
    scheduler.tick(computer.uptime())
    scheduler.drain()
    if onFrame then onFrame() end
    return quitting
end
function runtime.run(onFrame)
    while not quitting do
        runtime.frame(onFrame)
    end
    logs.system("主循环结束：" .. tostring(quitReason or "未说明原因"))
end
function runtime.bindQuitKeys()
    scheduler.on("interrupted", function()
        runtime.quit("Ctrl+C")
    end)
    scheduler.on("key_down", function(ev)
        local char, code = ev[3], ev[4]
        if utils.isKey(char, code, "q") then runtime.quit("按键 Q") end
    end)
end
return runtime
