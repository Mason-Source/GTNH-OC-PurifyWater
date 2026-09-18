--------------------------------------------------------------------------------
-- backend/handlers.lua
--------------------------------------------------------------------------------
-- 【职责】事件订阅表：**只做接线**，一行一个事件 -> 一个处理函数
-- 【被谁用】main.lua / monitor.lua（启动时调 handlers.subscribe()）
--
-- v2 把 `scheduler.on(...)` 散在 main / dispatch / unitScan，
--   查"谁响应了什么"要翻三个文件；这里一眼看全。
--
-- 【事件总表（ARCHITECTURE.md §4）】
--   采集类  hardware_missing  -> system（全关 + 锁定）
--           hardware_changed  -> system（全关+锁定 -> 记录作废）
--           power_changed     -> system（记录作废 -> 在跑时重排）
--           fluid_state       -> watch（开启条件判定 + 翻转广播）
--           fluid_unavailable -> watch（报警 + 停机锁定）
--           plant_observed    -> watch（边沿 + 归因）
--           parallel_sample   -> watch（连续确认 -> parallel_write / discarded）
--   派生类  level_rules_changed   -> watch（重判全部等级 + 重排）
--           level_openable_changed-> watch（立刻重排）
--           parallel_write        -> watch（写盘 + 重算功率 + 重排）
--           switch_mismatch       -> system（停机 + 锁定，不动机器）
--           主机开关                -> 不走事件：watch 每轮观测对一次（电平语义，见 app/system）
--   控制类  system_start / system_stop / priority_toggle / schedule_now
--------------------------------------------------------------------------------

local scheduler = require("core.scheduler")

local watch     = require("backend.app.watch")
local system    = require("backend.app.system")

local handlers  = {}

--- 订阅全部事件
-- @return number 订阅条数
function handlers.subscribe()
    -- 采集类
    scheduler.on("hardware_missing", system.onHardwareMissing)
    scheduler.on("hardware_changed", system.onHardwareChanged)
    scheduler.on("power_changed", system.onPowerChanged)
    scheduler.on("fluid_state", watch.onFluidState)
    scheduler.on("fluid_unavailable", watch.onFluidUnavailable)
    scheduler.on("plant_observed", watch.onPlantObserved)
    scheduler.on("parallel_sample", watch.onParallelSample)

    -- 派生类
    scheduler.on("level_rules_changed", watch.onLevelRulesChanged)
    scheduler.on("level_openable_changed", watch.onLevelOpenableChanged)
    scheduler.on("parallel_discarded", watch.onParallelDiscarded)
    scheduler.on("parallel_write", watch.onParallelWrite)
    scheduler.on("switch_mismatch", system.onSwitchMismatch)

    -- 控制类
    scheduler.on("system_start", system.onSystemStart)
    scheduler.on("system_stop", system.onSystemStop)
    scheduler.on("priority_toggle", system.onPriorityToggle)
    scheduler.on("schedule_now", watch.onScheduleNow)

    return 16
end

return handlers
