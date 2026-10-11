--------------------------------------------------------------------------------
-- backend/store/rates_config.lua
--------------------------------------------------------------------------------
-- 【职责】速率模式的**权重 + T7 增产倍率**配置：读写 data/settings.txt，并做变更检测
-- 【不做什么】不做业务判断、不认识旧版配置
-- 【依赖】shared/{config,constants,state}、backend/store/settings、domain/rates（档位规整）
-- 【被谁用】main（启动 load）、jobs（T2 每 5 秒 load 一次做变更检测）、backend/app/rates（改后写回）
--
-- 【键】weight.N = 该级"净产出权重"（0..MAX 整数，N = 1..8）｜t7_boost = T7 增产倍率（任一档位）
--   缺键/写坏 -> 默认值兜底并补写回文件；变更检测只看这几个键（别的键改了不会误触发重排）。
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

--- 缺键就补默认值（新装/手改删键都重新生成这几个键；已存在的值一律不动）
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

--- 读配置 -> state.rates / state.system.t7Boost；返回内容是否变化
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

    state.rates = weights
    state.system.t7Boost = boost
    return true, string.format("速率配置已更新（%d 级权重 ｜ T7 增产 ×%s）",
        constants.LEVEL_COUNT, tostring(boost))
end

--- 写某一级的权重（命令/界面改完调用）
-- @param level number
-- @param weight number
-- @return boolean ok
-- @return string|nil 失败原因
function rates_config.setWeight(level, weight)
    local w = sanitizeWeight(weight)
    state.rates[level] = w
    local ok, err = settings.setMany({ [weightKey(level)] = w })
    if not ok then return false, err end
    lastText = fingerprint(state.rates, state.system.t7Boost)
    return true
end

--- 写 T7 增产倍率（认不出的档位 -> 默认档）
-- @param value number
-- @return boolean ok
-- @return string|nil 失败原因
function rates_config.setBoost(value)
    local boost = rates.acceptBoost(value)
    state.system.t7Boost = boost
    local ok, err = settings.setMany({ t7_boost = boost })
    if not ok then return false, err end
    lastText = fingerprint(state.rates, state.system.t7Boost)
    return true
end

return rates_config
