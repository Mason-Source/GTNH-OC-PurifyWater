local constants = require("shared.constants")
local state     = require("shared.state")
local power     = {}
function power.adopted(level)
    local learn = state.read.learn(level)
    if learn and type(learn.parallel) == "number" and learn.parallel > 0 then
        return learn.parallel, "measured"
    end
    return power.suggest(level), "suggest"
end
function power.levelParallel(level)
    return power.adopted(level) * math.max(0, state.read.plant(level).deployed or 0)
end
function power.levelPower(level)
    return power.levelParallel(level) * (constants.POWER_LEVELS[level] or 0)
end
function power.suggest(level)
    return state.read.suggest(level)
end
function power.suggestVector()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = math.floor(tonumber(state.read.suggest(level)) or 0)
    end
    return out
end
function power.refresh()
    state.write.setBudget(state.read.powerAll())
end
return power
