local constants = require("shared.constants")
local F = {
    facts   = { plants = {}, fluids = {}, powerMax = 0 },
    learn   = {},
    config  = { rules = {}, weights = {}, mode = "threshold", priority = "low",
                enforceThreshold = true, t7Boost = 1, energyFactor = 100, netStrength = 20 },
    session = { running = false, awaiting = false, awaitReason = nil, lastSuggest = nil,
                autostart = false, autostartStale = false, autostartPath = nil },
    plan    = { suggest = {}, lastPlan = {}, notes = {}, budget = 0 },
    chart   = { points = {} },
    net     = { enabled = false, frame = 0, warned = nil },
    tracker = {}
}
local state = {}
local read  = {}
local write = {}
function read.plant(level)
    local p = F.facts.plants[level]
    if not p then
        p = { deployed = 0 }
        F.facts.plants[level] = p
    end
    return p
end
function read.fluids()   return F.facts.fluids end
function read.powerMax() return F.facts.powerMax or 0 end
function read.energyFactor() return F.config.energyFactor or 100 end
function read.netStrength() return F.config.netStrength or 0 end
function read.powerAll()
    return math.floor((F.facts.powerMax or 0) * (F.config.energyFactor or 100) / 100)
end
function read.rules()    return F.config.rules end
function read.weights()  return F.config.weights end
function read.mode()     return F.config.mode end
function read.priority() return F.config.priority end
function read.enforceThreshold() return F.config.enforceThreshold end
function read.t7Boost()  return F.config.t7Boost end
function read.running()  return F.session.running end
function read.awaiting() return F.session.awaiting end
function read.awaitReason() return F.session.awaitReason end
function read.baseline() return F.session.lastSuggest end
function read.autostart() return F.session.autostart end
function read.autostartStale() return F.session.autostartStale end
function read.autostartPath()  return F.session.autostartPath end
function read.learn(level) return F.learn[level] end
function read.suggest(level) return F.plan.suggest[level] or 0 end
function read.lastPlan() return F.plan.lastPlan end
function read.notes()    return F.plan.notes end
function read.budget()   return F.plan.budget or 0 end
function read.chart()    return F.chart end
function read.net()      return F.net end
function read.tracker()  return F.tracker end
function read.serviceTop()
    local top = 0
    for level = 1, constants.LEVEL_COUNT do
        if (read.plant(level).deployed or 0) > 0 then
            top = level
        else
            break
        end
    end
    return top
end
function read.priorityOrder()
    local order = {}
    if F.config.priority == "high" then
        for level = constants.LEVEL_COUNT, 1, -1 do order[#order + 1] = level end
    else
        for level = 1, constants.LEVEL_COUNT do order[#order + 1] = level end
    end
    return order
end
function write.recordPlant(level, fields)
    local p = read.plant(level)
    for key, value in pairs(fields or {}) do
        p[key] = value
    end
end
function write.setLastSwitch(level, value)
    read.plant(level).lastSwitch = value
end
function write.setFluids(values)
    for level = 1, constants.LEVEL_COUNT do
        F.facts.fluids[level] = (values and values[level]) or 0
    end
end
function write.setPowerMax(value)
    F.facts.powerMax = value or 0
end
function write.learnSet(level, parallel, source, success)
    local l = F.learn[level]
    if not l then l = {} F.learn[level] = l end
    l.parallel, l.source = parallel, source
    if success ~= nil then read.plant(level).success = success end
end
function write.learnClear(level)
    if level then
        local l = F.learn[level]
        if l then l.parallel, l.source = nil, nil end
    else
        for lv = 1, constants.LEVEL_COUNT do write.learnClear(lv) end
    end
end
function write.setRules(t)    F.config.rules = t or {} end
function write.setRuleLevel(level, rule) F.config.rules[level] = rule end
function write.setWeights(t)  F.config.weights = t or {} end
function write.setWeightLevel(level, w) F.config.weights[level] = w end
function write.setMode(v)     F.config.mode = v end
function write.setPriority(v) F.config.priority = v end
function write.setEnforce(v)  F.config.enforceThreshold = v end
function write.setBoost(v)    F.config.t7Boost = v end
function write.setEnergyFactor(v) F.config.energyFactor = v end
function write.netSetStrength(v) F.config.netStrength = tonumber(v) or 0 end
function write.setRunning(v)  F.session.running = (v == true) end
function write.setAwaiting(reason)
    F.session.awaiting    = true
    F.session.awaitReason = tostring(reason or "等待处理")
end
function write.clearAwaiting()
    local why = F.session.awaitReason
    F.session.awaiting, F.session.awaitReason = false, nil
    return why
end
function write.setBaseline(v)   F.session.lastSuggest = v end
function write.setAutostart(on, stale, path)
    F.session.autostart      = (on == true)
    F.session.autostartStale = (stale == true)
    F.session.autostartPath  = path
end
function write.publishSuggest(level, value) F.plan.suggest[level] = value end
function write.setLastPlan(t)  F.plan.lastPlan = t end
function write.deleteLastPlanLevel(level) F.plan.lastPlan[level] = nil end
function write.clearPlan()     F.plan.lastPlan = {} end
function write.setNotes(t)     F.plan.notes = t or {} end
function write.setBudget(v)    F.plan.budget = v or 0 end
function write.chartSetPoints(t) F.chart.points = t or {} end
function write.chartAppend(point) F.chart.points[#F.chart.points + 1] = point end
function write.netSetEnabled(v) F.net.enabled = (v == true) end
function write.netSetFrame(v)   F.net.frame = v or 0 end
function write.netSetWarned(v)  F.net.warned = v end
function write.trackerSet(address, t) F.tracker[address] = t end
function write.trackerDelete(address) F.tracker[address] = nil end
function write.trackerReset()         F.tracker = {} end
state.read           = read
state.write          = write
state.serviceTop     = read.serviceTop
state.priorityOrder  = read.priorityOrder
return state
