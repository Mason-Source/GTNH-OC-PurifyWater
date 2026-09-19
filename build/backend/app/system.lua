local CONFIG          = require("shared.config")
local constants       = require("shared.constants")
local logs            = require("shared.logs")
local state           = require("shared.state")
local computer        = require("computer")
local actuator        = require("backend.domain.actuator")
local tracker         = require("backend.domain.tracker")
local records         = require("backend.store.records")
local plan            = require("backend.app.plan")
local HOST_OFF_REASON = "主机开关已关"
local system          = {}
function system.start(reason)
    if state.plant(constants.HOST_LEVEL).switch == false then
        system.ensureHostStoppedLock()
        logs.warn("无法启动：净水主机开关是关的（请先在主机上打开）")
        return false
    end
    if state.system.locked then system.unlock() end
    state.system.running = true
    logs.system(string.format("启动（%s）", tostring(reason or "-")))
    plan.forget()
    plan.run("启动")
    return true
end
function system.stop(reason)
    local count = actuator.shutdownAll()
    state.system.running = false
    plan.forget()
    logs.system(string.format("停机（%s）：已下发全关 %d 台", tostring(reason or "-"), count))
end
function system.lock(why)
    state.system.locked     = true
    state.system.lockReason = tostring(why or "锁定")
    logs.warn("已锁定：" .. state.system.lockReason)
end
function system.unlock()
    if not state.system.locked then return false end
    local why = state.system.lockReason
    state.system.locked, state.system.lockReason = false, nil
    logs.system("已解锁（原锁定原因：" .. tostring(why) .. "）")
    return true
end
function system.enterSafeState(why, allOff)
    if state.system.locked then return false end
    if allOff then
        system.stop(why)
    else
        state.system.running = false
        logs.system(string.format("停机（%s）：保持 T1-8 现状，未下发任何指令", why))
    end
    system.lock(why)
    return true
end
function system.onHardwareMissing(payload)
    local what = table.concat((payload and payload.missing) or { "未知" }, "、")
    system.enterSafeState("硬件缺失：" .. what, true)
end
function system.ensureHostStoppedLock()
    return system.enterSafeState(HOST_OFF_REASON, true)
end
function system.onSwitchMismatch(payload)
    if not payload or not payload.level then return end
    if state.system.locked then return end
    local levelName    = constants.levelLabel(payload.level)
    local receipt      = actuator.lastReceipt()
    local sent, failed = 0, 0
    for _, item in ipairs(receipt.items or {}) do
        sent = sent + 1
        if not item.ok then failed = failed + 1 end
    end
    local since    = (receipt.at and receipt.at > 0)
        and string.format("%d 秒前", math.max(0, math.floor(computer.uptime() - receipt.at)))
        or "无记录"
    local sentText = (sent == 0) and "还没有过下发记录"
        or string.format("最近一次下发 %s %d 台（失败 %d）", since, sent, failed)
    logs.warn(string.format(
        "%s 实测%s，与调度意图（%s）不符（紧接我们下发之后） —— %s。停机并锁定（不动机器），处理完请点【启动系统】",
        levelName, payload.got and "开" or "关", payload.want and "开" or "关", sentText))
    system.enterSafeState(levelName .. " 开关与调度意图不符", false)
end
function system.onHardwareChanged(payload)
    tracker.resetAll()
    if CONFIG.SYSTEM.RELEARN_ON_UNIT_CHANGE and payload then
        for _, level in ipairs(payload.levels or {}) do
            logs.system(records.invalidate(level, "该级机器增减"))
        end
    end
    system.enterSafeState("硬件变更", true)
end
function system.onPowerChanged(payload)
    if CONFIG.SYSTEM.RELEARN_ON_POWER_CHANGE then
        logs.system(records.invalidate(nil, string.format("全厂功率 %s -> %s",
            tostring(payload and payload.from), tostring(payload and payload.to))))
    end
    if not state.isActive() then return end
    plan.run("功率变化")
end
function system.onSystemStart(payload)
    system.start(payload and payload.reason)
end
function system.onSystemStop(payload)
    system.stop(payload and payload.reason)
end
function system.onPriorityToggle()
    plan.togglePriority()
end
function system.toggle(reason)
    if state.system.running then
        system.stop(reason or "手动")
        return false
    end
    system.start(reason or "手动")
    return true
end
return system
