local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local state     = require("shared.state")
local rates     = {}
function rates.acceptBoost(value)
    local v = tonumber(value) or CONFIG.RATES.DEFAULT_T7_BOOST
    for _, option in ipairs(constants.T7_BOOST_OPTIONS) do
        if math.abs(v - option) < 0.001 then return option end
    end
    return CONFIG.RATES.DEFAULT_T7_BOOST
end
local function refluxOf(level)
    return constants.RATE_REFLUX_LEVELS[level] == true
end
function rates.successOf(level)
    local s = constants.RATE_SUCCESS[level] or 0
    if refluxOf(level) then s = s + constants.RATE_REFLUX_BONUS end
    return math.min(1, s)
end
function rates.weightOf(level)
    local w = tonumber(state.read.weights()[level]) or CONFIG.RATES.DEFAULT_WEIGHT
    if w < 0 then w = 0 end
    if w > CONFIG.RATES.MAX_WEIGHT then w = CONFIG.RATES.MAX_WEIGHT end
    return w
end
function rates.wanted(level)
    for k = level, state.serviceTop() do
        if rates.weightOf(k) > 0 then return true end
    end
    return false
end
function rates.allZero()
    return not rates.wanted(1)
end
function rates.plan()
    local top = state.serviceTop()
    local boost = rates.acceptBoost(state.read.t7Boost())
    local net, weights, counts = {}, {}, {}
    for level = 1, constants.LEVEL_COUNT do
        local gross = constants.RATE_PRODUCE * rates.successOf(level)
        if level == constants.T7_LEVEL then gross = gross * boost end
        net[level]     = gross - (refluxOf(level) and constants.RATE_REFLUX or 0)
        weights[level] = rates.weightOf(level)
        counts[level]  = math.max(0, state.read.plant(level).deployed or 0)
    end
    local margin = 1 + (CONFIG.RATES.ZERO_MARGIN or 0)
    local unitQ, unitDemand, needs = {}, {}, {}
    local nextQ = 0
    for level = top, 1, -1 do
        local carry = constants.RATE_CONSUME * nextQ
        if weights[level] <= 0 and carry > 0 then
            carry = carry * margin
        end
        local demand = weights[level] + carry
        local q      = (net[level] > 0) and (demand / net[level]) or 0
        unitQ[level], unitDemand[level] = q, demand
        needs[level] = demand > 0
        nextQ = q
    end
    for level = 1, constants.LEVEL_COUNT do
        if level > top then
            unitQ[level], unitDemand[level], needs[level] = 0, 0, false
        end
    end
    local power  = state.read.powerAll()
    local unitPower = 0
    for level = 1, top do
        unitPower = unitPower + unitQ[level] * (constants.POWER_LEVELS[level] or 0)
    end
    local lambdaPower = (unitPower > 0 and power > 0) and (power / unitPower) or 0
    local lambdaCap = math.huge
    for level = 1, top do
        if unitQ[level] > 0 and counts[level] > 0 then
            local ratio = (constants.parallelCap(level) * counts[level]) / unitQ[level]
            if ratio < lambdaCap then lambdaCap = ratio end
        end
    end
    if lambdaCap == math.huge then lambdaCap = 0 end
    local lambda = math.min(lambdaPower, lambdaCap)
    local suggest, total, notes = {}, {}, {}
    for level = 1, top do
        local c    = counts[level]
        local raw  = (c > 0) and (lambda * unitQ[level] / c) or 0
        local per  = math.floor(raw)
        suggest[level] = per
        total[level]   = per * c
        if per < 1 and needs[level] and lambda > 0 then
            notes[#notes + 1] = { level = level, kind = "too_small" }
        end
    end
    for level = top + 1, constants.LEVEL_COUNT do
        suggest[level], total[level] = 0, 0
    end
    for level = 1, top - 1 do
        local c       = counts[level + 1]
        local supply  = total[level] * net[level]
        local maxNext = math.floor(math.max(0, supply) / constants.RATE_CONSUME)
        local pMax    = (c > 0) and math.floor(maxNext / c) or 0
        if suggest[level + 1] > pMax then
            local from = suggest[level + 1]
            suggest[level + 1] = pMax
            total[level + 1]   = pMax * c
            notes[#notes + 1]  = { level = level + 1, kind = "trimmed", from = from, to = pMax }
        end
    end
    return {
        suggest = suggest,
        notes   = notes,
        want    = unitQ,
        limit   = { lambdaPower = lambdaPower, lambdaCap = lambdaCap },
    }
end
return rates
