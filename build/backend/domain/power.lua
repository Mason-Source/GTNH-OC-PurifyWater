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
    local budget = state.power.all or 0
    local count  = math.max(1, state.plant(level).deployed or 0)
    local per    = constants.POWER_LEVELS[level] or 0
    if per <= 0 or budget <= 0 then return 1 end
    local limit   = (level == 1) and 2386092 or 2147483
    local allowed = math.floor(budget / (per * count))
    return math.max(1, math.min(limit, allowed))
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
