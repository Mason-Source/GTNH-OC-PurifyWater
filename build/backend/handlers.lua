local scheduler = require("core.scheduler")
local watch     = require("backend.app.watch")
local system    = require("backend.app.system")
local rates     = require("backend.app.rates")
local handlers  = {}
function handlers.subscribe()
    scheduler.on("hardware_missing", system.onHardwareMissing)
    scheduler.on("hardware_changed", system.onHardwareChanged)
    scheduler.on("power_changed", system.onPowerChanged)
    scheduler.on("deployed_changed", system.onDeployedChanged)
    scheduler.on("plant_observed", watch.onPlantObserved)
    scheduler.on("parallel_sample", watch.onParallelSample)
    scheduler.on("level_rules_changed", watch.onLevelRulesChanged)
    scheduler.on("rates_changed", rates.onRatesChanged)
    scheduler.on("mode_changed", rates.onModeChanged)
    scheduler.on("enforce_changed", rates.onEnforceChanged)
    scheduler.on("parallel_discarded", watch.onParallelDiscarded)
    scheduler.on("parallel_write", system.onParallelWrite)
    scheduler.on("switch_mismatch", system.onSwitchMismatch)
    scheduler.on("rules_audit", system.auditThresholds)
    scheduler.on("schedule_now", system.onScheduleRequest)
    return 15
end
return handlers
