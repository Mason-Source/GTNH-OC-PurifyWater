local scheduler = require("core.scheduler")
local watch     = require("backend.app.watch")
local system    = require("backend.app.system")
local handlers  = {}
function handlers.subscribe()
    scheduler.on("hardware_missing", system.onHardwareMissing)
    scheduler.on("hardware_changed", system.onHardwareChanged)
    scheduler.on("power_changed", system.onPowerChanged)
    scheduler.on("plant_observed", watch.onPlantObserved)
    scheduler.on("parallel_sample", watch.onParallelSample)
    scheduler.on("level_rules_changed", watch.onLevelRulesChanged)
    scheduler.on("rates_changed", watch.onRatesChanged)
    scheduler.on("parallel_discarded", watch.onParallelDiscarded)
    scheduler.on("parallel_write", system.onParallelWrite)
    scheduler.on("switch_mismatch", system.onSwitchMismatch)
    scheduler.on("rules_audit", system.auditThresholds)
    scheduler.on("schedule_now", system.onScheduleRequest)
    return 12
end
return handlers
