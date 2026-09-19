local constants = require("shared.constants")
local state = {}
state.plants = {}
state.fluids = {}
state.power = { all = 0, budget = 0 }
state.tracker = {}
state.system = {
    running    = false,
    locked     = false,
    lockReason = nil,
    priority   = "low"  
}
state.chart = { points = {} }
state.net = { enabled = false, frame = 0, warned = nil }
state.rules = {}
state.lastPlan = {}
state.dirty = {}
function state.plant(level)
    local p = state.plants[level]
    if not p then
        p = { deployed = 0 }
        state.plants[level] = p
    end
    return p
end
function state.markDirty(what)
    state.dirty[what] = true
end
function state.isDirty(what)
    return state.dirty[what] == true
end
function state.clearDirty(what)
    state.dirty[what] = nil
end
function state.isActive()
    return state.system.running == true and state.system.locked == false
end
function state.priorityOrder()
    local order = {}
    if state.system.priority == "high" then
        for level = constants.LEVEL_COUNT, 1, -1 do order[#order + 1] = level end
    else
        for level = 1, constants.LEVEL_COUNT do order[#order + 1] = level end
    end
    return order
end
return state
