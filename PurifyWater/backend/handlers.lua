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
--   配置类  level_rules_changed -> watch（审计提示 + 重排）
--           rates_changed       -> rates（生效性门 -> 发布 -> 忘方案 -> 审计 -> 重排）
--           mode_changed        -> rates（发布 -> 忘方案 -> 审计 -> 重排）
--           enforce_changed     -> rates（忘方案 + 重排，不发布）
--   派生类  parallel_write     -> system（内存学习 + 重算规则 + 重排）
--           switch_mismatch    -> system（停会话 + 等待用户，不动机器）
--           主机开关             -> 不走事件：watch 每轮观测对一次（电平语义，见 app/system）
--   制作自动化类 produce_changed -> system（开关 / 就绪性 / 缺料变化 -> 重判）+ produce（取消过期 operation）
--                plant_observed  -> produce（active / 门控变化 -> 取消过期 operation）
--                host_cycle_started -> produce（登记制作任务）+ watch（周期并行样本）
--   控制类  schedule_now       -> system（界面刷新触发一次立即调度）
--------------------------------------------------------------------------------

local scheduler = require("core.scheduler")

local system    = require("backend.app.system")
local produceApp = require("backend.app.produce")

local handlers  = {}
local watch     = nil
local rates     = nil

-- 事件映射模块只在对应事件首次出现时加载，避免挡在首帧之前。
local function watchApp()
    watch = watch or require("backend.app.watch")
    return watch
end

local function ratesApp()
    rates = rates or require("backend.app.rates")
    return rates
end

--- 订阅全部事件
-- @return number 订阅条数
function handlers.subscribe()
    -- 采集类
    scheduler.on("hardware_missing", system.onHardwareMissing)
    scheduler.on("hardware_changed", system.onHardwareChanged)
    scheduler.on("power_changed", system.onPowerChanged)
    scheduler.on("deployed_changed", system.onDeployedChanged)
    scheduler.on("plant_observed", function(...) return watchApp().onPlantObserved(...) end)

    -- 配置类
    scheduler.on("level_rules_changed", function(...) return watchApp().onLevelRulesChanged(...) end)
    scheduler.on("rates_changed", function(...) return ratesApp().onRatesChanged(...) end)
    scheduler.on("mode_changed", function(...) return ratesApp().onModeChanged(...) end)
    scheduler.on("enforce_changed", function(...) return ratesApp().onEnforceChanged(...) end)

    -- 派生类
    scheduler.on("parallel_write", system.onParallelWrite)
    scheduler.on("switch_mismatch", system.onSwitchMismatch)
    scheduler.on("rules_audit", system.auditThresholds)

    -- 制作自动化类
    scheduler.on("produce_changed", system.onProduceChanged)
    scheduler.on("produce_changed", produceApp.syncJobs)
    scheduler.on("plant_observed", produceApp.syncJobs)
    scheduler.on("host_cycle_started", produceApp.onCycleStarted)
    scheduler.on("host_cycle_started", function(...) return watchApp().onHostCycleStarted(...) end)

    -- 控制类
    scheduler.on("schedule_now", system.onScheduleRequest)

    return 18
end

return handlers
