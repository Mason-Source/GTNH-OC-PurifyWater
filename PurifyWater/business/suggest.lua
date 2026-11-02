--------------------------------------------------------------------------------
-- PurifyWater/business/suggest.lua
--
-- 定位：速率模式下的并行建议计算器。
-- 功能：根据权重、成功率、回流、T6/T7 参数和能源预算计算各等级建议并行。
-- 边界：只读快照并返回计算值；不持久化、不下发开关、不访问组件。
--------------------------------------------------------------------------------

local CONFIG = require("shared.config")
local constants = require("shared.constants")

local suggest = {}

local function serviceTop(snapshot)
    local top = 0
    for level = 1, constants.LEVEL_COUNT do
        local row = (snapshot.facts.levels or {})[level] or {}
        if (tonumber(row.deployed) or 0) > 0 then
            top = level
        else
            break
        end
    end
    return top
end
suggest.serviceTop = serviceTop

local function weightOf(snapshot, level)
    local value = tonumber((snapshot.settings.weights or {})[level])
        or CONFIG.RATES.DEFAULT_WEIGHT
    return math.max(0, math.min(CONFIG.RATES.MAX_WEIGHT, value))
end
suggest.weightOf = weightOf

local function refluxOf(snapshot, level)
    local configured = (snapshot.settings.reflux or {})[level]
    if type(configured) == "boolean" then return configured end
    return constants.RATE_REFLUX_LEVELS[level] == true
end
suggest.refluxOf = refluxOf

--- 返回考虑回流奖励与 T6 双锂选项后的有效成功率。
function suggest.successOf(snapshot, level)
    local success = constants.RATE_SUCCESS[level] or 0
    if level == constants.T6_LEVEL and snapshot.settings.t6DualLithium == true then
        success = constants.RATE_SUCCESS_DUAL_LITHIUM
    end
    if refluxOf(snapshot, level) then
        success = success + constants.RATE_REFLUX_BONUS
    end
    return math.min(1, success)
end

local function wanted(snapshot, level, top)
    for current = level, top do
        if weightOf(snapshot, current) > 0 then return true end
    end
    return false
end
suggest.wanted = wanted

local function thresholdValues(snapshot)
    local budget = tonumber(snapshot.power.available) or 0
    local top = serviceTop(snapshot)
    local values = {}
    for level = 1, constants.LEVEL_COUNT do
        local value = 0
        if level <= top then
            local count = math.max(1, tonumber(((snapshot.facts.levels or {})[level] or {}).deployed) or 0)
            local perPower = constants.POWER_LEVELS[level] or 0
            if perPower <= 0 or budget <= 0 then
                value = 1
            else
                value = math.max(1, math.min(constants.parallelCap(level),
                    math.floor(budget / (perPower * count))))
            end
        end
        values[level] = value
    end
    return values, { top = top, budget = budget }
end

local function rateValues(snapshot)
    local top = serviceTop(snapshot)
    local budget = tonumber(snapshot.power.available) or 0
    local boost = tonumber(snapshot.settings.t7Boost) or CONFIG.RATES.DEFAULT_T7_BOOST
    local net, weights, counts = {}, {}, {}
    for level = 1, constants.LEVEL_COUNT do
        local gross = constants.RATE_PRODUCE * suggest.successOf(snapshot, level)
        if level == constants.T7_LEVEL then gross = gross * boost end
        net[level] = gross - (refluxOf(snapshot, level) and constants.RATE_REFLUX or 0)
        weights[level] = weightOf(snapshot, level)
        counts[level] = math.max(0, tonumber(((snapshot.facts.levels or {})[level] or {}).deployed) or 0)
    end

    local unitQ, unitDemand = {}, {}
    local nextQ = 0
    local margin = 1 + (CONFIG.RATES.ZERO_MARGIN or 0)
    for level = top, 1, -1 do
        local carry = constants.RATE_CONSUME * nextQ
        if weights[level] <= 0 and carry > 0 then carry = carry * margin end
        local demand = weights[level] + carry
        local q = net[level] > 0 and (demand / net[level]) or 0
        unitQ[level], unitDemand[level] = q, demand
        nextQ = q
    end
    for level = 1, constants.LEVEL_COUNT do
        if level > top then unitQ[level], unitDemand[level] = 0, 0 end
    end

    local unitPower = 0
    for level = 1, top do
        unitPower = unitPower + unitQ[level] * (constants.POWER_LEVELS[level] or 0)
    end
    local lambdaPower = (unitPower > 0 and budget > 0) and (budget / unitPower) or 0
    local lambdaCap = math.huge
    for level = 1, top do
        if unitQ[level] > 0 and counts[level] > 0 then
            local ratio = constants.parallelCap(level) * counts[level] / unitQ[level]
            if ratio < lambdaCap then lambdaCap = ratio end
        end
    end
    if lambdaCap == math.huge then lambdaCap = 0 end
    local lambda = math.min(lambdaPower, lambdaCap)

    local values, total, notes = {}, {}, {}
    for level = 1, top do
        local count = counts[level]
        local raw = count > 0 and (lambda * unitQ[level] / count) or 0
        local per = math.floor(raw)
        values[level], total[level] = per, per * count
        if per < 1 and unitDemand[level] > 0 and lambda > 0 then
            notes[#notes + 1] = { level = level, kind = "too_small" }
        end
    end
    for level = top + 1, constants.LEVEL_COUNT do
        values[level], total[level] = 0, 0
    end

    for level = 1, top - 1 do
        local count = counts[level + 1]
        local supply = total[level] * net[level]
        local maxNext = math.floor(math.max(0, supply) / constants.RATE_CONSUME)
        local perMax = count > 0 and math.floor(maxNext / count) or 0
        if values[level + 1] > perMax then
            notes[#notes + 1] = {
                level = level + 1,
                kind = "trimmed",
                from = values[level + 1],
                to = perMax,
            }
            values[level + 1] = perMax
            total[level + 1] = perMax * count
        end
    end

    return values, {
        top = top,
        budget = budget,
        notes = notes,
        want = unitQ,
        limit = { lambdaPower = lambdaPower, lambdaCap = lambdaCap },
    }
end

--- 按当前调度模式计算 T1-T8 的建议每机并行及元数据。
function suggest.compute(snapshot)
    local mode = snapshot.settings.mode == "rate" and "rate" or "threshold"
    local values, meta
    if mode == "rate" then
        values, meta = rateValues(snapshot)
    else
        values, meta = thresholdValues(snapshot)
    end
    meta.mode = mode
    meta.values = values
    return meta
end

--- 生成建议计算的稳定输入指纹，用于跳过高成本重算。
function suggest.inputKey(snapshot)
    local mode = snapshot.settings.mode == "rate" and "rate" or "threshold"
    local parts = {
        mode,
        tostring(math.floor(tonumber(snapshot.power.available) or 0)),
    }
    for level = 1, constants.LEVEL_COUNT do
        local row = (snapshot.facts.levels or {})[level] or {}
        parts[#parts + 1] = tostring(math.floor(tonumber(row.deployed) or 0))
    end
    if mode == "rate" then
        for level = 1, constants.LEVEL_COUNT do
            parts[#parts + 1] = tostring(weightOf(snapshot, level))
        end
        for _, level in ipairs({ 1, 2, constants.T6_LEVEL }) do
            parts[#parts + 1] = tostring(refluxOf(snapshot, level))
        end
        parts[#parts + 1] = tostring(snapshot.settings.t6DualLithium == true)
        parts[#parts + 1] = tostring(tonumber(snapshot.settings.t7Boost) or 1)
    end
    return table.concat(parts, "|")
end

--- 比较两组 T1-T8 建议并行是否完全一致。
function suggest.equals(a, b)
    for level = 1, constants.LEVEL_COUNT do
        if (tonumber((a or {})[level]) or 0) ~= (tonumber((b or {})[level]) or 0) then
            return false
        end
    end
    return true
end

--- 复制并向下取整规范化 T1-T8 建议并行。
function suggest.copy(values)
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = math.floor(tonumber((values or {})[level]) or 0)
    end
    return out
end

return suggest