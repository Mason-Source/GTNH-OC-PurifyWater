local constants       = require("shared.constants")
local logs            = require("shared.logs")
local state           = require("shared.state")
local utils           = require("shared.utils")
local computer        = require("computer")
local scheduler       = require("core.scheduler")
local actuator        = require("backend.domain.actuator")
local tracker         = require("backend.domain.tracker")
local learning        = require("backend.domain.learning")
local mode            = require("backend.domain.mode")
local power           = require("backend.domain.power")
local plan            = require("backend.app.plan")
local HOST_OFF_REASON = "主机开关已关"
local system          = {}
local lastWarnSig     = nil
local lastZeroWarn    = nil
function system.publish()
    local text = mode.publish()
    if text and text ~= "" then logs.warn(text) end
end
function system.effect()
    local rate   = state.system.mode == "rate"
    local gated  = (not rate) or (state.system.enforceThreshold == true)
    return {
        enabled   = gated,
        threshold = gated,
        weight    = rate,
        boost     = rate
    }
end
function system.requestPlan(reason)
    if not state.isActive() then return false end
    if system.checkSuggestionChange() then return false end
    return plan.run(reason)
end
function system.resetSuggestBaseline()
    state.system.lastSuggest = power.suggestVector()
end
function system.checkSuggestionChange()
    local now = power.suggestVector()
    local was = state.system.lastSuggest
    if not was then
        state.system.lastSuggest = now
        return false
    end
    local changed = {}
    for level = 1, constants.LEVEL_COUNT do
        local a, b = tonumber(was[level]) or 0, tonumber(now[level]) or 0
        if a ~= b then changed[#changed + 1] = { level = level, from = a, to = b } end
    end
    if #changed == 0 then return false end
    state.system.lastSuggest = now
    if not state.isActive() then return false end
    local texts = {}
    for _, item in ipairs(changed) do
        texts[#texts + 1] = string.format("%s %s→%s", constants.levelLabel(item.level),
            tostring(item.from), tostring(item.to))
    end
    logs.debug("[调试] 建议并行变化（已锁定）：" .. table.concat(texts, "、"))
    system.enterSafeState("建议并行已变化", true, "请按新建议调好机器并行，再点【启动系统】")
    return true
end
function system.auditThresholds()
    local texts, signature, warnText, debugTexts = mode.audit()
    texts     = texts or {}
    signature = signature or ""
    debugTexts = debugTexts or {}
    if warnText then
        if warnText ~= lastZeroWarn then
            logs.warn(warnText)
            lastZeroWarn = warnText
        end
    else
        lastZeroWarn = nil
    end
    if signature == lastWarnSig then return end
    lastWarnSig = signature
    for _, text in ipairs(texts) do logs.warn(text) end
    for _, text in ipairs(debugTexts) do logs.debug(text) end
end
function system.resetLearning(why)
    tracker.resetAll()
    learning.forgetAll()
    scheduler.emit("rules_audit", { reason = why })
end
local function beginSession(reason)
    system.resetLearning(reason)
    state.system.running = true
    plan.forget()
    system.resetSuggestBaseline()
    logs.system("并行学习已重置：本轮将从建议值重新学习真实并行")
end
local function endSession(reason)
    state.system.running = false
    system.resetLearning(reason)
    plan.forget()
end
function system.start(reason)
    if state.system.running then return true end
    if state.plant(constants.HOST_LEVEL).switch == false then
        system.ensureHostStoppedLock()
        logs.warn("无法启动：净水主机开关是关的（请先在主机上打开）")
        return false
    end
    logs.system(string.format("启动（%s）", tostring(reason or "-")))
    if state.system.locked then system.unlock() end
    beginSession(reason)
    system.auditThresholds()
    system.requestPlan("启动")
    return true
end
function system.stop(reason)
    local count = actuator.shutdownAll()
    endSession(reason)
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
function system.enterSafeState(why, allOff, line)
    if state.system.locked then return false end
    if line then logs.warn(line) end
    if allOff then
        system.stop(why)
    else
        endSession(why)
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
    system.enterSafeState(levelName .. " 开关被人工改动", false, string.format(
        "%s 实测%s，方案要%s。停机并锁定（机器保持现状），处理完请点【启动系统】｜ %s",
        levelName, payload.got and "开" or "关", payload.want and "开" or "关", sentText))
end
function system.onHardwareChanged()
    system.enterSafeState("硬件变更", true)
end
function system.onPowerChanged(payload)
    system.resetLearning(string.format("功率变化 %s -> %s",
        tostring(payload and payload.from), tostring(payload and payload.to)))
    system.requestPlan("功率变化")
end
function system.onParallelWrite(payload)
    if not payload or not learning.remember(payload.level, payload.parallel, payload.success) then
        return false
    end
    logs.system(string.format("%s 本次实际并行 = %s（来源：%s）",
        constants.levelLabel(payload.level), utils.formatShortNumber(payload.parallel),
        tostring(payload.by or "传感器确认")))
    system.auditThresholds()
    system.requestPlan("并行更新")
    return true
end
function system.onPriorityToggle()
    plan.togglePriority()
    system.requestPlan("优先级切换")
end
function system.onScheduleRequest(payload)
    system.requestPlan(payload and payload.reason or "事件")
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
