--------------------------------------------------------------------------------
-- backend/store/rates_config.lua
--------------------------------------------------------------------------------
-- 【职责】权重 + T7 增产倍率配置：读写 settings.txt 并变更检测
-- 【不做什么】不判业务
-- 【依赖】shared/{config,constants,state}、store/settings、domain/rates
-- 【被谁用】main、jobs（T2）、app/rates
--
-- 键：weight.N（0..MAX 整数）/ t7_boost；缺键兜底补写；变更检测只看这些键。
--------------------------------------------------------------------------------

local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local state        = require("shared.state")

local settings     = require("backend.store.settings")
local rates        = require("backend.domain.rates")

local rates_config = {}

local lastText     = nil

--- 权重键（键名只在这里拼）
local function weightKey(level) return "weight." .. tostring(level) end

--- 权重 -> 规整后的整数（0..MAX；认不出/写坏用默认值）
-- @param value any
-- @return number
local function sanitizeWeight(value)
    local w = tonumber(value)
    if not w then return CONFIG.RATES.DEFAULT_WEIGHT end
    w = math.floor(w)
    if w < 0 then w = 0 end
    if w > CONFIG.RATES.MAX_WEIGHT then w = CONFIG.RATES.MAX_WEIGHT end
    return w
end

--- 规则表 -> 指纹文本（只覆盖权重/倍率，用于变更检测）
-- @param weights table
-- @param boost number
-- @return string
local function fingerprint(weights, boost)
    local parts = { "boost=" .. tostring(boost) }
    for level = 1, constants.LEVEL_COUNT do
        parts[#parts + 1] = string.format("%d=%d", level, weights[level] or 0)
    end
    return table.concat(parts, "|")
end

--- 缺键补默认值；已存在的值不动
-- @param snapshot table
-- @return table 补完后的快照
-- @return number 补了几个键（0 = 没写盘）
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

--- 读配置 -> config.weights / config.t7Boost；返回内容是否变化
-- @param snapshot table|nil 已读好的 settings 表（周期扫描一次读全后共用；不传就自己读一次）
-- @return boolean changed
-- @return string 说明
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

--- 写单级权重
-- @param level number
-- @param weight number
-- @return boolean ok
-- @return string|nil 失败原因
function rates_config.setWeight(level, weight)
    local w = sanitizeWeight(weight)
    state.write.setWeightLevel(level, w)
    local ok, err = settings.setMany({ [weightKey(level)] = w })
    if not ok then return false, err end
    lastText = fingerprint(state.read.weights(), state.read.t7Boost())
    return true
end

--- 写 T7 增产倍率（认不出的档位 -> 默认档）
-- @param value number
-- @return boolean ok
-- @return string|nil 失败原因
function rates_config.setBoost(value)
    local boost = rates.acceptBoost(value)
    state.write.setBoost(boost)
    local ok, err = settings.setMany({ t7_boost = boost })
    if not ok then return false, err end
    lastText = fingerprint(state.read.weights(), state.read.t7Boost())
    return true
end

return rates_config
