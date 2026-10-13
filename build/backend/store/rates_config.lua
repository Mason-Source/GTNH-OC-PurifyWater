local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local state        = require("shared.state")
local settings     = require("backend.store.settings")
local rates        = require("backend.domain.rates")
local rates_config = {}
local lastText     = nil
local function weightKey(level) return "weight." .. tostring(level) end
local function sanitizeWeight(value)
    local w = tonumber(value)
    if not w then return CONFIG.RATES.DEFAULT_WEIGHT end
    w = math.floor(w)
    if w < 0 then w = 0 end
    if w > CONFIG.RATES.MAX_WEIGHT then w = CONFIG.RATES.MAX_WEIGHT end
    return w
end
local function fingerprint(weights, boost)
    local parts = { "boost=" .. tostring(boost) }
    for level = 1, constants.LEVEL_COUNT do
        parts[#parts + 1] = string.format("%d=%d", level, weights[level] or 0)
    end
    return table.concat(parts, "|")
end
local function ensureKeys(snapshot)
    local pairsToSet, missing = {}, 0
    for level = 1, constants.LEVEL_COUNT do
        if snapshot[weightKey(level)] == nil then
            pairsToSet[weightKey(level)] = CONFIG.RATES.DEFAULT_WEIGHT
            missing = missing + 1
        end
    end
    if snapshot["t7_boost"] == nil then
        pairsToSet["t7_boost"] = CONFIG.RATES.DEFAULT_T7_BOOST
        missing = missing + 1
    end
    if missing == 0 then return snapshot, 0 end
    settings.setMany(pairsToSet)
    for key, value in pairs(pairsToSet) do snapshot[key] = tostring(value) end
    return snapshot, missing
end
function rates_config.load(snapshot)
    snapshot = ensureKeys(snapshot or settings.load() or {})
    local weights = {}
    for level = 1, constants.LEVEL_COUNT do
        weights[level] = sanitizeWeight(snapshot[weightKey(level)])
    end
    local boost = rates.acceptBoost(snapshot["t7_boost"])
    local text = fingerprint(weights, boost)
    if text == lastText then return false, "速率配置未变化" end
    lastText = text
    state.write.setWeights(weights)
    state.write.setBoost(boost)
    return true, string.format("速率配置已更新（%d 级权重 ｜ T7 增产 ×%s）",
        constants.LEVEL_COUNT, tostring(boost))
end
function rates_config.setWeight(level, weight)
    local w = sanitizeWeight(weight)
    state.write.setWeightLevel(level, w)
    local ok, err = settings.setMany({ [weightKey(level)] = w })
    if not ok then return false, err end
    lastText = fingerprint(state.read.weights(), state.read.t7Boost())
    return true
end
function rates_config.setBoost(value)
    local boost = rates.acceptBoost(value)
    state.write.setBoost(boost)
    local ok, err = settings.setMany({ t7_boost = boost })
    if not ok then return false, err end
    lastText = fingerprint(state.read.weights(), state.read.t7Boost())
    return true
end
return rates_config
