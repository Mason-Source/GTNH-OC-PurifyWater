-- ReadModel -> ConfigView：配置表、全局字段与选项键盘的数据来源。
local constants = require("shared.constants")
local util = require("shared.util")

local config = {}

local function numberText(value)
    value = tonumber(value) or 0
    if value == math.floor(value) then return tostring(value) end
    return string.format("%g", value)
end

function config.build(read)
    local settings = read.settings or {}
    local system = read.system or {}
    local produce = (read.produce and read.produce.levels) or {}
    local rows = {}

    for level = 1, constants.LEVEL_COUNT do
        local source = (read.levels or {})[level] or {}
        local rule = source.rule or {}
        local collectText = "-"
        if level == 1 or level == 2 then
            local on = (settings.reflux or {})[level] == true
            collectText = "回流[" .. (on and "√" or " ") .. "]"
        elseif level == constants.T6_LEVEL then
            collectText = "双锂[" .. (settings.t6DualLithium and "√" or " ") .. "]"
        elseif level == constants.T7_LEVEL then
            collectText = "×" .. numberText(settings.t7Boost)
        end

        local product = produce[level] or {}
        local produceText, produceRole = "-", "disabled"
        if product.implemented then
            if product.enabled then
                if product.ready then
                    produceText, produceRole = "[√]", "success"
                else
                    produceText, produceRole = "[!]", "warning"
                end
            elseif product.ready then
                produceText, produceRole = "[○]", "muted"
            else
                produceText, produceRole = "[ ]", "disabled"
            end
        end
        rows[level] = {
            level = level,
            label = constants.levelLabel(level),
            enabled = rule.enabled ~= false,
            thresholdL = tonumber(rule.threshold) or 0,
            thresholdK = math.floor((tonumber(rule.threshold) or 0) / 1000),
            thresholdText = util.formatNumber(math.floor((tonumber(rule.threshold) or 0) / 1000)),
            weight = tonumber((settings.weights or {})[level]) or 0,
            weightText = numberText((settings.weights or {})[level]),
            collectText = collectText,
            produceText = produceText,
            produceRole = produceRole,
            produceEnabled = product.enabled == true,
            produceReady = product.ready == true,
            produceClickable = product.implemented ~= false,
        }
    end

    return {
        revision = read.revision,
        rows = rows,
        system = {
            mode = system.mode,
            priority = system.priority,
            enforceThreshold = system.enforceThreshold,
            theme = system.theme,
            reflux = settings.reflux or {},
            t6DualLithium = settings.t6DualLithium == true,
            t7Boost = tonumber(settings.t7Boost) or 1,
            energyFactor = tonumber(settings.energyFactor) or 100,
        },
        net = {
            strength = tonumber((read.net or {}).strength) or 0,
        },
        produce = {
            levels = produce,
            binding = read.produce and read.produce.binding or nil,
        },
        settings = {
            autostart = settings.autostart == true,
            autostartStale = settings.autostartStale == true,
            autostartPath = settings.autostartPath,
        },
    }
end

return config
