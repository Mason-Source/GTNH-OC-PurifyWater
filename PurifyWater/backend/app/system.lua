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
local mode            = require("backend.domain.mode")
local power           = require("backend.domain.power")
local plan            = require("backend.app.plan")

-- 主机总开关被关时用的锁定原因（只写一处）
local HOST_OFF_REASON = "主机开关已关"

local system          = {}
local lastWarnSig     = nil
local lastZeroWarn    = nil   -- "全 0"这类整块提示：文本变了才再报一次，没有就复位

--- 统一调度请求：先过系统活动状态 -> 建议基线检查 -> 再交给 plan
-- @param reason string
-- @return boolean
function system.requestPlan(reason)
    if not state.isActive() then return false end
    if system.checkSuggestionChange() then return false end -- 建议变了：已全关+锁定，本轮不排计划
    return plan.run(reason)
end

--- 把"建议并行基线"设为当前建议（启动会话时调用：以当前建议为基准，不触发锁定）
function system.resetSuggestBaseline()
    state.system.lastSuggest = power.suggestVector()
end

--- 检查"建议并行"是否相对本次会话基线变了；变了就**全关 + 锁定**（明细只进 debug）
-- 【只比整数建议】不看实测并行/学习值 —— 玩家按建议调机器时不会被反复锁。
-- 【首建不锁】没有基线时只记基线；【停机/锁定期间不锁】只更新基线（启动会话时还会再重置一次）。
-- @return boolean 是否因此锁定（true = 调用方本轮不要再排计划）
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
    if not state.isActive() then return false end -- 停机/锁定期间：只更新基线，不锁

    local texts = {}
    for _, item in ipairs(changed) do
        texts[#texts + 1] = string.format("%s %s→%s", constants.levelLabel(item.level),
            tostring(item.from), tostring(item.to))
    end
    logs.debug("[调试] 建议并行变化（已锁定）：" .. table.concat(texts, "、"))

    system.enterSafeState("建议并行已变化", true, "请按新建议调好机器并行，再点【启动系统】")
    return true
end

--- 检查"一次性提示"（阈值低于保供线 / 全 0 / 速率模式备注…）
-- 【模式化】文本/指纹/整块提示都由当前模式给（mode.audit），"只报一次"的哨兵留在这里（通用机制）
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

--- 清空本轮并行学习与采样确认器
function system.resetLearning(why)
    tracker.resetAll()
    learning.forgetAll()
    scheduler.emit("rules_audit", { reason = why })
end

--- 开始一次运行会话：清学习值，置运行态，忘掉旧方案
local function beginSession(reason)
    system.resetLearning(reason)
    state.system.running = true
    plan.forget()
    system.resetSuggestBaseline() -- 启动会话：以"当前建议"为基线（用户刚按建议调好机器才点的启动）
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
    system.auditThresholds()
    system.requestPlan("并行更新")
    return true
end

-- 命令入口

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
