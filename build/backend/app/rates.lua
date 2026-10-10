local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local logs         = require("shared.logs")
local state        = require("shared.state")
local settings     = require("backend.store.settings")
local rates_config = require("backend.store.rates_config")
local mode         = require("backend.domain.mode")
local rates        = require("backend.domain.rates")
local plan         = require("backend.app.plan")
local system       = require("backend.app.system")
local app          = {}
local function afterChange(reason)
    mode.publish()
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
    logs.system(string.format("%s 权重 = %d", constants.levelLabel(level), weight))
    afterChange("权重变更")
    return true, ""
end
function app.cycleT7Boost()
    local options = constants.T7_BOOST_OPTIONS
    local current = rates.acceptBoost(state.system.t7Boost)
    local index = 1
    for i, option in ipairs(options) do
        if option == current then index = i end
    end
    local nextBoost = options[(index % #options) + 1]
    local ok, err = rates_config.setBoost(nextBoost)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end
    logs.system(string.format("T7 增产倍率：×%s", tostring(nextBoost)))
    afterChange("T7 增产倍率变更")
    return true, ""
end
return app
