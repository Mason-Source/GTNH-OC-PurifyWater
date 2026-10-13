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
    if not state.read.running() then
        return false
    end
    power.refresh()
    local result = allocator.plan()
    if result.warn then
        once("noPower", result.warn)
    else
        clearOnce("noPower")
    end
    local known = next(state.read.lastPlan()) ~= nil
    if known and allocator.isSame(state.read.lastPlan(), result.plan) then
        return false
    end
    local _, failed = actuator.apply(result.plan)
    state.write.setLastPlan(result.plan)
    local badNames = {}
    for level, err in pairs(failed or {}) do
        badNames[#badNames + 1] = constants.levelLabel(level)
        state.write.deleteLastPlanLevel(level)
        logs.debug(string.format("%s 下发失败：%s", constants.levelLabel(level), tostring(err)))
    end
    if #badNames > 0 then
        table.sort(badNames)
        logs.warn(string.format("%s 下发失败，下一轮重试",
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
    state.write.setPriority((state.read.priority() == "high") and "low" or "high")
    state.write.clearPlan()
    local ok              = settings.set("priority", state.read.priority())
    logs.system(string.format("运行模式：%s%s",
        state.read.priority() == "high" and "高级水优先" or "低级水优先",
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    return state.read.priority()
end
function plan.forget()
    state.write.clearPlan()
end
return plan
