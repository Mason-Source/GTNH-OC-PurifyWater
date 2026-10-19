--------------------------------------------------------------------------------
-- backend/handlers.lua
--------------------------------------------------------------------------------
-- 【职责】事件订阅表：只做接线，一行一个事件 -> 处理器
-- 【被谁用】main.lua、monitor.lua
--
-- 事件总表（ARCHITECTURE.md §4）
--   采集类  hardware_missing   -> system（运行中则全关停机）
--           hardware_changed   -> system（运行中：停会话+等待用户；非运行：只清学习）
--           power_changed      -> system（发布建议 -> 清本轮学习 -> 在跑时重排）
--           deployed_changed   -> system（发布建议，各状态恒发）
--           plant_observed     -> watch（边沿 + 归因 + 并行不一致）
--           parallel_sample    -> watch（连续确认 -> parallel_write / discarded）
--   配置类  level_rules_changed -> watch（审计提示 + 重排）
--           rates_changed       -> rates（生效性门 -> 发布 -> 忘方案 -> 审计 -> 重排）
--           mode_changed        -> rates（发布 -> 忘方案 -> 审计 -> 重排）
--           enforce_changed     -> rates（忘方案 + 重排，不发布）
--   派生类  parallel_write     -> system（内存学习 + 重算规则 + 重排）
--           switch_mismatch    -> system（停会话 + 等待用户，不动机器）
--           主机开关             -> 不走事件：watch 每轮观测对一次（电平语义，见 app/system）
--   制作自动化类 produce_changed -> system（开关 / 就绪性 / 缺料变化 -> 重判）+ produce（取消过期 operation）
--                plant_observed  -> produce（active / 门控变化 -> 取消过期 operation）
--                produce_cycle   -> produce（周期边界登记 operation）
--   控制类  schedule_now       -> system（界面刷新触发一次立即调度）
--------------------------------------------------------------------------------

local scheduler = require("core.scheduler")

local watch     = require("backend.app.watch")
local system    = require("backend.app.system")
local rates     = require("backend.app.rates")
local produceApp = require("backend.app.produce")

local handlers  = {}

--- 订阅全部事件
-- @return number 订阅条数
function handlers.subscribe()
    -- 采集类
    scheduler.on("hardware_missing", system.onHardwareMissing)
    scheduler.on("hardware_changed", system.onHardwareChanged)
    scheduler.on("power_changed", system.onPowerChanged)
    scheduler.on("deployed_changed", system.onDeployedChanged)
    scheduler.on("plant_observed", watch.onPlantObserved)
    scheduler.on("parallel_sample", watch.onParallelSample)

    -- 配置类
    scheduler.on("level_rules_changed", watch.onLevelRulesChanged)
    scheduler.on("rates_changed", rates.onRatesChanged)
    scheduler.on("mode_changed", rates.onModeChanged)
    scheduler.on("enforce_changed", rates.onEnforceChanged)

    -- 派生类
    scheduler.on("parallel_discarded", watch.onParallelDiscarded)
    scheduler.on("parallel_write", system.onParallelWrite)
    scheduler.on("switch_mismatch", system.onSwitchMismatch)
    scheduler.on("rules_audit", system.auditThresholds)

    -- 制作自动化类
    scheduler.on("produce_changed", system.onProduceChanged)
    scheduler.on("produce_changed", produceApp.syncJobs)
    scheduler.on("plant_observed", produceApp.syncJobs)
    scheduler.on("produce_cycle", produceApp.onCycleStarted)

    -- 控制类
    scheduler.on("schedule_now", system.onScheduleRequest)

    return 19
end

return handlers
