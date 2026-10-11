local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local logs         = require("shared.logs")
local state        = require("shared.state")
local settings     = require("backend.store.settings")
local rates_config = require("backend.store.rates_config")
local mode         = require("backend.domain.mode")
local plan         = require("backend.app.plan")
local system       = require("backend.app.system")
local IDLE_NOTE    = "（当前模式不生效，已保存待用）"
local app          = {}
local function afterChange(reason)
    system.publish()
    plan.forget()
    system.auditThresholds()
    system.requestPlan(reason)
end
function app.toggleMode()
    local nextId = (state.system.mode == "rate") and "threshold" or "rate"
    state.system.mode = nextId
    local ok = settings.set("mode", nextId)
    logs.system(string.format("调度模式：%s%s", mode.labelOf(nextId),
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    afterChange("调度模式切换")
    return nextId
end
function app.toggleEnforceThreshold()
    state.system.enforceThreshold = not state.system.enforceThreshold
    local ok = settings.set("enforce_threshold", state.system.enforceThreshold)
    logs.system(string.format("速率模式：%s水位阈值约束%s",
        state.system.enforceThreshold and "受" or "不受",
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    afterChange("阈值约束切换")
    return state.system.enforceThreshold
end
function app.setWeight(level, weight)
    level, weight = tonumber(level), tonumber(weight)
    if not level or level < 1 or level > constants.LEVEL_COUNT then
        return false, "等级无效"
    end
    if not weight or weight < 0 or weight > CONFIG.RATES.MAX_WEIGHT
        or weight ~= math.floor(weight) then
        return false, string.format("权重需为 0-%d 的整数", CONFIG.RATES.MAX_WEIGHT)
    end
    local ok, err = rates_config.setWeight(level, weight)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end
    logs.system(string.format("%s 权重 = %d%s", constants.levelLabel(level), weight,
        system.effect().weight and "" or IDLE_NOTE))
    afterChange("权重变更")
    return true, ""
end
function app.setT7Boost(value)
    value = tonumber(value)
    local options, matched = constants.T7_BOOST_OPTIONS, false
    for _, option in ipairs(options) do
        if option == value then matched = true break end
    end
    if not matched then
        return false, string.format("增产倍率只能是 %s", table.concat(options, " / "))
    end
    local ok, err = rates_config.setBoost(value)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end
    logs.system(string.format("T7 增产倍率：×%s%s", tostring(value),
        system.effect().boost and "" or IDLE_NOTE))
    afterChange("T7 增产倍率变更")
    return true, ""
end
return app
