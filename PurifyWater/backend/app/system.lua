--------------------------------------------------------------------------------
-- backend/app/system.lua
--------------------------------------------------------------------------------
-- 【职责】系统生命周期：启动 / 停机 / 暂停锁定 / 会话重置 / 调度总闸 / 阈值警告
-- 【不做什么】不采集硬件、不判断开关事实、不计算规则、不下发单台机器
--
-- 【状态】
--   state.system.running    系统是否在自动调度
--   state.system.locked     锁定：出过需要人来处理的事，不自动恢复
--   state.system.lockReason 锁定原因（只记第一条）
--
-- 【会话边界】每次从停止进入运行，并行学习值都清空并从建议值重新学习；
--   停止、暂停、锁定、硬件变化、功率变化都走同一套重置逻辑。
--------------------------------------------------------------------------------

local constants       = require("shared.constants")
local logs            = require("shared.logs")
local state           = require("shared.state")
local utils           = require("shared.utils")
local computer        = require("computer")
local scheduler       = require("core.scheduler")

local actuator        = require("backend.domain.actuator")
local tracker         = require("backend.domain.tracker")
local learning        = require("backend.domain.learning")
local rules           = require("backend.domain.rules")
local plan            = require("backend.app.plan")

-- 主机总开关被关时用的锁定原因（只写一处）
local HOST_OFF_REASON = "主机开关已关"

local system          = {}
local lastWarnSig     = nil
local warnedAllZero   = false

--- 统一调度请求：先过系统活动状态，再交给 plan
-- @param reason string
-- @return boolean
function system.requestPlan(reason)
    if not state.isActive() then return false end
    return plan.run(reason)
end

--- 检查用户阈值是否低于实际执行阈值；同一状态只警告一次
function system.auditThresholds()
    local texts, sig = {}, {}
    local hasPositive = false
    for level = 1, constants.LEVEL_COUNT do
        local rule = state.rules[level]
        local line = rules.lines(level)
        if rule and (rule.threshold or 0) > 0 then hasPositive = true end
        if line.overridden then
            texts[#texts + 1] = string.format(
                "%s 用户阈值 %s 低于下一级保供线 %s，实际按 %s 执行",
                constants.levelLabel(level),
                utils.formatShortNumber(line.user),
                utils.formatShortNumber(line.next),
                utils.formatShortNumber(line.actual))
            sig[#sig + 1] = table.concat({ level, line.user, line.next }, ":")
        end
    end

    if not hasPositive then
        if not warnedAllZero then
            logs.warn("所有等级的用户阈值均为 0，暂按低保线执行；请前往【配置】页面设置阈值")
            warnedAllZero = true
        end
    else
        warnedAllZero = false
    end

    local signature = table.concat(sig, "|")
    if signature == lastWarnSig then return end
    lastWarnSig = signature
    for _, text in ipairs(texts) do logs.warn(text) end
end

--- 清空本轮并行学习与采样确认器
function system.resetLearning(why)
    tracker.resetAll()
    learning.forgetAll()
    rules.refreshAll()
    scheduler.emit("rules_audit", { reason = why })
end

--- 开始一次运行会话：清学习值，置运行态，忘掉旧方案
local function beginSession(reason)
    system.resetLearning(reason)
    state.system.running = true
    plan.forget()
    logs.system("并行学习已重置：本轮将从建议值重新学习真实并行")
end

--- 结束一次运行会话：置停止态，清学习值，忘掉旧方案
local function endSession(reason)
    state.system.running = false
    system.resetLearning(reason)
    plan.forget()
end

--- 启动（开始自动调度；锁定后唯一的手动恢复入口）
-- @param reason string
-- @return boolean 是否真的启动了
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

--- 停机（下发全关）
-- @param reason string
function system.stop(reason)
    local count = actuator.shutdownAll()
    endSession(reason)
    logs.system(string.format("停机（%s）：已下发全关 %d 台", tostring(reason or "-"), count))
end

--- 锁定（不再自动恢复，直到解锁）
-- @param why string
function system.lock(why)
    state.system.locked     = true
    state.system.lockReason = tostring(why or "锁定")
    logs.warn("已锁定：" .. state.system.lockReason)
end

--- 解锁；唯一调用者是 system.start
-- @return boolean 是否真的解锁了
function system.unlock()
    if not state.system.locked then return false end
    local why = state.system.lockReason
    state.system.locked, state.system.lockReason = false, nil
    logs.system("已解锁（原锁定原因：" .. tostring(why) .. "）")
    return true
end

--- 进安全状态：结束会话 + 锁定
-- allOff = true  先全关；false 保持机器现状
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

-- 事件入口

--- 硬件缺失 -> 全关 + 锁定
function system.onHardwareMissing(payload)
    local what = table.concat((payload and payload.missing) or { "未知" }, "、")
    system.enterSafeState("硬件缺失：" .. what, true)
end

--- 主机开关是关的 -> 确保全关 + 锁定
function system.ensureHostStoppedLock()
    return system.enterSafeState(HOST_OFF_REASON, true)
end

--- 实测开关偏离方案 -> 停机 + 锁定，不动机器
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

--- 硬件台账变化 -> 清学习值 + 全关 + 锁定
function system.onHardwareChanged()
    system.enterSafeState("硬件变更", true)
end

--- 全厂功率变化 -> 清本轮学习值，在运行中则重排
function system.onPowerChanged(payload)
    system.resetLearning(string.format("功率变化 %s -> %s",
        tostring(payload and payload.from), tostring(payload and payload.to)))
    system.requestPlan("功率变化")
end

--- 并行学习值更新 -> 重算规则并立即重排
function system.onParallelWrite(payload)
    if not payload or not learning.remember(payload.level, payload.parallel, payload.success) then
        return false
    end
    logs.system(string.format("%s 本次实际并行 = %s（来源：%s）",
        constants.levelLabel(payload.level), utils.formatShortNumber(payload.parallel),
        tostring(payload.by or "传感器确认")))
    rules.refreshAll()
    system.auditThresholds()
    system.requestPlan("并行更新")
    return true
end

-- 命令入口

function system.onSystemStart(payload)
    system.start(payload and payload.reason)
end

function system.onSystemStop(payload)
    system.stop(payload and payload.reason)
end

function system.onPriorityToggle()
    plan.togglePriority()
    system.requestPlan("优先级切换")
end

--- 所有“条件变化后请求重排”的统一入口
function system.onScheduleRequest(payload)
    system.requestPlan(payload and payload.reason or "事件")
end

--- 开关系统（界面一个键搞定）
function system.toggle(reason)
    if state.system.running then
        system.stop(reason or "手动")
        return false
    end
    system.start(reason or "手动")
    return true
end

return system
