local constants = require("shared.constants")
local logs      = require("shared.logs")
local state     = require("shared.state")
local utils     = require("shared.utils")
local power     = require("backend.domain.power")
local allocator = require("backend.domain.allocator")
local actuator  = require("backend.domain.actuator")
local settings  = require("backend.store.settings")
local plan      = {}
local warned    = {}
local function once(key, text)
    if warned[key] then return end
    warned[key] = true
    logs.append(text)
end
local function clearOnce(key)
    warned[key] = nil
end
function plan.run(reason)
    if not state.isActive() then
        return false
    end
    power.refresh()
    local result = allocator.plan()
    if result.warn then
        once("noPower", result.warn)
    else
        clearOnce("noPower")
    end
    local known = next(state.lastPlan) ~= nil
    if known and allocator.isSame(state.lastPlan, result.plan) then
        return false
    end
    local _, failed = actuator.apply(result.plan)
    state.lastPlan = result.plan
    local badNames = {}
    for level, err in pairs(failed or {}) do
        badNames[#badNames + 1] = constants.levelLabel(level)
        state.lastPlan[level]   = nil
        logs.debug(string.format("[调试] %s 下发失败：%s", constants.levelLabel(level), tostring(err)))
    end
    if #badNames > 0 then
        table.sort(badNames)
        logs.warn(string.format("%s 的开关没发出去（本轮不算数，下一轮再试）",
            table.concat(badNames, "、")))
    end
    logs.schedule(string.format("%s：%s ｜ 功率 %s / %s ｜ %s",
        tostring(reason or "-"),
        allocator.describe(result.plan),
        utils.formatShortNumber(result.used), utils.formatShortNumber(result.budget),
        actuator.describeReceipt()))
    return true
end
function plan.togglePriority()
    state.system.priority = (state.system.priority == "high") and "low" or "high"
    state.lastPlan        = {}
    local ok              = settings.set("priority", state.system.priority)
    logs.system(string.format("运行模式：%s%s",
        state.system.priority == "high" and "高级水优先" or "低级水优先",
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    if state.isActive() then plan.run("优先级切换") end
    return state.system.priority
end
function plan.forget()
    state.lastPlan = {}
end
return plan
