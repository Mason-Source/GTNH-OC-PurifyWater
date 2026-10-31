-- 配置用例：校验、更新内存、写 settings.txt、推进 revision。
local CONFIG = require("shared.config")
local constants = require("shared.constants")
local state = require("services.state")
local settings = require("services.settings_store")
local log = require("services.log")
local util = require("shared.util")

local config_service = {}

local function bool(value, fallback)
    if type(value) == "boolean" then return value end
    local text = tostring(value or ""):lower()
    if text == "true" or text == "1" or text == "on" then return true end
    if text == "false" or text == "0" or text == "off" then return false end
    return fallback
end

local function clamp(value, minimum, maximum, fallback)
    value = tonumber(value)
    if not value then return fallback end
    value = math.floor(value)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function boost(value)
    value = tonumber(value)
    for _, option in ipairs(constants.T7_BOOST_OPTIONS) do
        if value == option then return option end
    end
    return CONFIG.RATES.DEFAULT_T7_BOOST
end

local function theme(value)
    for _, option in ipairs(CONFIG.UI.THEMES or {}) do
        if value == option then return option end
    end
    return CONFIG.UI.DEFAULT_THEME
end

local function thresholdKey(level) return "threshold." .. tostring(level) end
local function enabledKey(level) return "enabled." .. tostring(level) end
local function weightKey(level) return "weight." .. tostring(level) end
local function refluxKey(level) return "reflux." .. tostring(level) end
local function produceKey(level) return "produce_enabled." .. tostring(level) end

local function applySnapshot(snapshot)
    local s = state.get().settings
    local net = state.get().net

    for level = 1, constants.LEVEL_COUNT do
        s.thresholds[level] = clamp(snapshot[thresholdKey(level)],
            0, 1e14 * 1000 - 1, CONFIG.LEVELS.DEFAULT_THRESHOLD)
        s.enabledLevels[level] = bool(snapshot[enabledKey(level)], CONFIG.LEVELS.DEFAULT_ENABLED)
        s.weights[level] = clamp(snapshot[weightKey(level)],
            0, CONFIG.RATES.MAX_WEIGHT, CONFIG.RATES.DEFAULT_WEIGHT)
        s.reflux[level] = bool(snapshot[refluxKey(level)], constants.RATE_REFLUX_LEVELS[level] == true)
        local product = state.get().produce.levels[level] or {}
        product.enabled = bool(snapshot[produceKey(level)], false)
        state.get().produce.levels[level] = product
    end

    s.t6DualLithium = bool(snapshot.t6_dual_lithium, false)
    s.t7Boost = boost(snapshot.t7_boost)
    s.energyFactor = clamp(snapshot.energy_factor,
        CONFIG.ENERGY.FACTOR_MIN, CONFIG.ENERGY.FACTOR_MAX, CONFIG.ENERGY.FACTOR_DEFAULT)
    s.netEnabled = bool(snapshot.net_enabled, false)
    net.enabled = s.netEnabled
    s.netStrength = clamp(snapshot.net_strength,
        0, CONFIG.NET.STRENGTH_MAX, CONFIG.NET.STRENGTH_DEFAULT)
    s.mode = snapshot.mode == "rate" and "rate" or "threshold"
    s.priority = snapshot.priority == "high" and "high" or "low"
    s.enforceThreshold = bool(snapshot.enforce_threshold, true)
    s.theme = theme(snapshot.theme)
    net.strength = s.netStrength
end

local function ensureKeys()
    local snapshot = settings.load() or {}
    local additions, missing = {}, 0
    for level = 1, constants.LEVEL_COUNT do
        if snapshot[thresholdKey(level)] == nil then
            additions[thresholdKey(level)] = CONFIG.LEVELS.DEFAULT_THRESHOLD
            missing = missing + 1
        end
        if snapshot[enabledKey(level)] == nil then
            additions[enabledKey(level)] = CONFIG.LEVELS.DEFAULT_ENABLED and "true" or "false"
            missing = missing + 1
        end
        if snapshot[weightKey(level)] == nil then
            additions[weightKey(level)] = CONFIG.RATES.DEFAULT_WEIGHT
            missing = missing + 1
        end
        if snapshot[refluxKey(level)] == nil then
            additions[refluxKey(level)] = constants.RATE_REFLUX_LEVELS[level] == true and "true" or "false"
            missing = missing + 1
        end
        if snapshot[produceKey(level)] == nil then
            additions[produceKey(level)] = "false"
            missing = missing + 1
        end
    end
    if snapshot.t6_dual_lithium == nil then additions.t6_dual_lithium = "false"; missing = missing + 1 end
    if snapshot.t7_boost == nil then additions.t7_boost = CONFIG.RATES.DEFAULT_T7_BOOST; missing = missing + 1 end
    if snapshot.energy_factor == nil then additions.energy_factor = CONFIG.ENERGY.FACTOR_DEFAULT; missing = missing + 1 end
    if snapshot.net_enabled == nil then additions.net_enabled = "false"; missing = missing + 1 end
    if snapshot.net_strength == nil then additions.net_strength = CONFIG.NET.STRENGTH_DEFAULT; missing = missing + 1 end
    if snapshot.mode == nil then additions.mode = "threshold"; missing = missing + 1 end
    if snapshot.priority == nil then additions.priority = "low"; missing = missing + 1 end
    if snapshot.enforce_threshold == nil then additions.enforce_threshold = "true"; missing = missing + 1 end
    if snapshot.theme == nil then additions.theme = CONFIG.UI.DEFAULT_THEME; missing = missing + 1 end


    if missing > 0 then
        local ok, err = settings.setMany(additions)
        if not ok then return nil, err end
        for key, value in pairs(additions) do snapshot[key] = tostring(value) end
    end
    return snapshot
end

function config_service.load()
    local snapshot, err = ensureKeys()
    if not snapshot then return false, err end
    applySnapshot(snapshot)
    state.bump()
    log.system("配置已载入")
    return true, settings.path()
end

local function commit(values, message)
    local ok, err = settings.setMany(values)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end
    local snapshot = settings.load() or {}
    applySnapshot(snapshot)
    state.bump()
    log.system(message or "配置已更新")
    return true, ""
end

function config_service.toggleEnabled(level)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    local current = state.get().settings.enabledLevels[level] ~= false
    local nextValue = not current
    return commit({ [enabledKey(level)] = nextValue and "true" or "false" },
        string.format("%s 勾选：%s", constants.levelCode(level), nextValue and "开" or "关"))
end

function config_service.setThreshold(level, liters)
    level = tonumber(level)
    liters = tonumber(liters)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if not liters or liters < 0 or liters >= 1e14 * 1000 then return false, "阈值超出范围" end
    liters = math.floor(liters)
    return commit({ [thresholdKey(level)] = liters },
        string.format("%s 阈值：%s kL", constants.levelCode(level),
            util.formatNumber(math.floor(liters / 1000))))
end

function config_service.setWeight(level, weight)
    level = tonumber(level)
    weight = tonumber(weight)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if not weight or weight < 0 or weight > CONFIG.RATES.MAX_WEIGHT then return false, "权重超出范围" end
    weight = math.floor(weight)
    return commit({ [weightKey(level)] = weight },
        string.format("%s 权重：%d", constants.levelCode(level), weight))
end

function config_service.setReflux(level, enabled)
    level = tonumber(level)
    if level ~= 1 and level ~= 2 then return false, "回流数据收集只支持 T1/T2" end
    if type(enabled) ~= "boolean" then return false, "开关值无效" end
    return commit({ [refluxKey(level)] = enabled and "true" or "false" },
        string.format("%s 回流收集：%s", constants.levelCode(level), enabled and "开" or "关"))
end

function config_service.setT6DualLithium(enabled)
    if type(enabled) ~= "boolean" then return false, "开关值无效" end
    return commit({ t6_dual_lithium = enabled and "true" or "false" },
        "T6 双锂收集：" .. (enabled and "双锂" or "标准"))
end

function config_service.setT7Boost(value)
    value = boost(value)
    return commit({ t7_boost = value }, "T7 增产倍率：×" .. tostring(value))
end

function config_service.setTheme(value)
    local valid = nil
    for _, option in ipairs(CONFIG.UI.THEMES or {}) do
        if value == option then valid = option; break end
    end
    if not valid then return false, "主题无效" end
    local label = (CONFIG.UI.THEME_LABELS or {})[valid] or valid
    return commit({ theme = valid }, "主题：" .. label)
end

function config_service.setEnergyFactor(value)
    value = tonumber(value)
    if not value or value < CONFIG.ENERGY.FACTOR_MIN or value > CONFIG.ENERGY.FACTOR_MAX
        or value ~= math.floor(value) then
        return false, "能源仓利用因子需为 1-100 的整数"
    end
    return commit({ energy_factor = value }, "能源仓利用因子：" .. tostring(value) .. "%")
end

function config_service.setNetStrength(value)
    value = tonumber(value)
    if not value or value < 0 or value > CONFIG.NET.STRENGTH_MAX
        or value ~= math.floor(value) then
        return false, "无线范围超出限制"
    end
    return commit({ net_strength = value }, "无线范围：" .. tostring(value))
end

function config_service.setProduceEnabled(level, enabled)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if type(enabled) ~= "boolean" then return false, "开关值无效" end
    if enabled then
        local ready, reason = require("services.produce_service").canEnable(level)
        if not ready then return false, reason end
    end
    return commit({ [produceKey(level)] = enabled and "true" or "false" },
        string.format("%s 制作自动化：%s", constants.levelCode(level), enabled and "启用" or "停用"))
end

function config_service.toggleMode()
    local nextMode = state.get().settings.mode == "rate" and "threshold" or "rate"
    return commit({ mode = nextMode }, "调度模式：" .. nextMode)
end

function config_service.togglePriority()
    local nextPriority = state.get().settings.priority == "high" and "low" or "high"
    return commit({ priority = nextPriority }, "优先级：" .. nextPriority)
end

function config_service.toggleEnforce()
    local nextValue = state.get().settings.enforceThreshold ~= true
    return commit({ enforce_threshold = nextValue and "true" or "false" },
        "阈值约束：" .. (nextValue and "开" or "关"))
end

function config_service.handle(name, action)
    action = action or {}
    if name == "level_enabled_toggle" then
        return config_service.toggleEnabled(action.level)
    elseif name == "config_commit" then
        local value = tonumber(action.value)
        if action.field == "threshold" then
            return config_service.setThreshold(action.level, value and value * 1000)
        elseif action.field == "weight" then
            return config_service.setWeight(action.level, value)
        elseif action.field == "factor" then
            return config_service.setEnergyFactor(value)
        elseif action.field == "strength" then
            return config_service.setNetStrength(value)
        end
    elseif name == "t7_boost_set" then
        return config_service.setT7Boost(action.value)
    elseif name == "reflux_set" then
        return config_service.setReflux(action.level, action.value == true)
    elseif name == "t6_dual_lithium_set" then
        return config_service.setT6DualLithium(action.value == true)
    elseif name == "theme_set" then
        return config_service.setTheme(action.value)
    elseif name == "produce_toggle" then
        return config_service.setProduceEnabled(action.level, action.value == true)
    elseif name == "mode_toggle" then
        return config_service.toggleMode()
    elseif name == "priority_toggle" then
        return config_service.togglePriority()
    elseif name == "threshold_enforce_toggle" then
        return config_service.toggleEnforce()
    end
    return nil
end

return config_service
