local constants = require("shared.constants")
local state     = require("shared.state")
local power     = {}
function power.adopted(level)
    local snap = state.plant(level)
    if type(snap.parallel) == "number" and snap.parallel > 0 then
        return snap.parallel, "measured"
    end
    return power.suggest(level), "suggest"
end
function power.levelParallel(level)
    return power.adopted(level) * math.max(0, state.plant(level).deployed or 0)
end
function power.levelPower(level)
    return power.levelParallel(level) * (constants.POWER_LEVELS[level] or 0)
end
function power.suggest(level)
    return state.plant(level).suggest or 0
end
function power.suggestVector()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = math.floor(tonumber(state.plant(level).suggest) or 0)
    end
    return out
end
function power.parallelMismatch()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        local snap = state.plant(level)
        if snap.sample and (snap.deployed or 0) > 0 then
            local suggest = power.suggest(level)
            if snap.sample ~= suggest then
                out[#out + 1] = { level = level, current = snap.sample, suggest = suggest }
            end
        end
    end
    return out
end
function power.refresh()
    state.power.budget = state.power.all or 0
end
return power
