--------------------------------------------------------------------------------
-- backend/store/rates_config.lua
--------------------------------------------------------------------------------
-- 【职责】权重 + 回流/双锂收集 + T7 增产倍率配置：读写 settings.txt 并变更检测
-- 【不做什么】不判业务
-- 【依赖】shared/{config,constants,state}、store/settings、domain/rates
-- 【被谁用】main、jobs（T2）、app/rates
--
-- 键：weight.N / reflux.1 / reflux.2 / t6_dual_lithium / t7_boost；缺键兜底补写。
--------------------------------------------------------------------------------

local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local models        = require("shared.models")
local state        = require("shared.state")

local settings     = require("backend.store.settings")
local rates        = require("backend.domain.rates")

local rates_config = {}

local lastText     = nil
local REFLUX_LEVELS = { 1, 2 }
local DUAL_LITHIUM_KEY = "t6_dual_lithium"

--- 权重键（键名只在这里拼）
local function weightKey(level) return "weight." .. tostring(level) end

--- 回流数据收集键（界面只开放 T1/T2，手改其它级也兼容）
local function refluxKey(level) return "reflux." .. tostring(level) end

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
-- @param reflux table
-- @param dualLithium boolean
-- @return string
local function fingerprint(weights, boost, reflux, dualLithium)
    local parts = {
        "boost=" .. tostring(boost),
        "dual=" .. tostring(dualLithium == true)
    }
    for level = 1, constants.LEVEL_COUNT do
        parts[#parts + 1] = string.format("%d=%d", level, weights[level] or 0)
        parts[#parts + 1] = string.format("reflux%d=%s", level,
            reflux[level] == true and "true" or "false")
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
    for _, level in ipairs(REFLUX_LEVELS) do
        if snapshot[refluxKey(level)] == nil then
            pairsToSet[refluxKey(level)] = constants.RATE_REFLUX_LEVELS[level] == true
            missing = missing + 1
        end
    end
    if snapshot[DUAL_LITHIUM_KEY] == nil then
        pairsToSet[DUAL_LITHIUM_KEY] = CONFIG.RATES.DEFAULT_T6_DUAL_LITHIUM
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
    local reflux = {}
    for level = 1, constants.LEVEL_COUNT do
        reflux[level] = models.bool(snapshot[refluxKey(level)],
            constants.RATE_REFLUX_LEVELS[level] == true)
    end
    local dualLithium = models.bool(snapshot[DUAL_LITHIUM_KEY],
        CONFIG.RATES.DEFAULT_T6_DUAL_LITHIUM)

    local text = fingerprint(weights, boost, reflux, dualLithium)
    if text == lastText then return false, "速率配置未变化" end
    lastText = text

    state.write.setWeights(weights)
    state.write.setBoost(boost)
    state.write.setReflux(reflux)
    state.write.setT6DualLithium(dualLithium)
    return true, string.format(
        "速率配置已更新（%d 级权重 ｜ T7 增产 ×%s ｜ 回流 T1=%s T2=%s ｜ T6 双锂=%s）",
        constants.LEVEL_COUNT, tostring(boost),
        reflux[1] and "开" or "关", reflux[2] and "开" or "关", dualLithium and "开" or "关")
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
    lastText = fingerprint(state.read.weights(), state.read.t7Boost(),
        state.read.reflux(), state.read.t6DualLithium())
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
    lastText = fingerprint(state.read.weights(), state.read.t7Boost(),
        state.read.reflux(), state.read.t6DualLithium())
    return true
end

--- 写某一级的回流数据收集开关（仅界面开放的 T1/T2）
-- @param level number
-- @param enabled boolean
-- @return boolean ok
-- @return string|nil 失败原因
function rates_config.setReflux(level, enabled)
    local allowed = false
    for _, item in ipairs(REFLUX_LEVELS) do
        if item == level then allowed = true break end
    end
    if not allowed then return false, "回流数据收集只支持 T1/T2" end
    if type(enabled) ~= "boolean" then return false, "开关值无效" end

    local ok, err = settings.setMany({ [refluxKey(level)] = enabled })
    if not ok then return false, err end
    state.write.setRefluxLevel(level, enabled)
    lastText = fingerprint(state.read.weights(), state.read.t7Boost(),
        state.read.reflux(), state.read.t6DualLithium())
    return true
end

--- 写 T6 是否使用双锂数据收集
-- @param enabled boolean
-- @return boolean ok
-- @return string|nil 失败原因
function rates_config.setT6DualLithium(enabled)
    if type(enabled) ~= "boolean" then return false, "开关值无效" end
    local ok, err = settings.setMany({ [DUAL_LITHIUM_KEY] = enabled })
    if not ok then return false, err end
    state.write.setT6DualLithium(enabled)
    lastText = fingerprint(state.read.weights(), state.read.t7Boost(),
        state.read.reflux(), state.read.t6DualLithium())
    return true
end

return rates_config
