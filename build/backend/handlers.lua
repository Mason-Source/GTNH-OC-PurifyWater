local scheduler = require("core.scheduler")
local watch     = require("backend.app.watch")
local system    = require("backend.app.system")
local handlers  = {}
function handlers.subscribe()
    scheduler.on("hardware_missing", system.onHardwareMissing)
    scheduler.on("hardware_changed", system.onHardwareChanged)
    scheduler.on("power_changed", system.onPowerChanged)
    scheduler.on("fluid_state", watch.onFluidState)
    scheduler.on("fluid_unavailable", watch.onFluidUnavailable)
    scheduler.on("plant_observed", watch.onPlantObserved)
    scheduler.on("parallel_sample", watch.onParallelSample)
    scheduler.on("level_rules_changed", watch.onLevelRulesChanged)
    scheduler.on("level_openable_changed", watch.onLevelOpenableChanged)
    scheduler.on("parallel_discarded", watch.onParallelDiscarded)
    scheduler.on("parallel_write", watch.onParallelWrite)
    scheduler.on("switch_mismatch", system.onSwitchMismatch)
    scheduler.on("system_start", system.onSystemStart)
    scheduler.on("system_stop", system.onSystemStop)
    scheduler.on("priority_toggle", system.onPriorityToggle)
    scheduler.on("schedule_now", watch.onScheduleNow)
    return 16
end
return handlers
