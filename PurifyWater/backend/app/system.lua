--------------------------------------------------------------------------------
-- backend/app/system.lua
--------------------------------------------------------------------------------
-- 【职责】系统生命周期：启动/停机/等待用户/会话重置/调度总闸/建议发布/阈值警告
-- 【不做什么】不采集硬件、不判开关事实、不算规则、不下发单台机器
--
-- 【状态】
--   session.running     系统是否在自动调度（唯一行为门）
--   session.awaiting    等待用户：出过需要人来处理的事，不自动恢复
--   session.awaitReason 等待原因（只记第一条）
--
-- 会话边界：停止进入运行时清学习值并从建议值重学；停机/等待/硬件/功率变化同一套重置。
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

-- 主机开关关闭的停机原因（只写一处）
local HOST_OFF_REASON = "主机已关机"

local system          = {}
local lastWarnSig      = nil
local lastZeroWarn     = nil   -- 整块提示哨兵
local lastPublishDrain = -1    -- 最近一次发布的派发序号（同一次派发只发一次）

--- 重新生成建议并发布（受控点专用）
-- 同一次派发内只发一次：触发事实虽多，但发布输入在派发前都已写完，结果相同。
-- 返回的扩产警告每次发布都显示，不走 audit 的去重。
function system.publish()
    local seq = scheduler.drainSeq()
    if seq == lastPublishDrain then return end
    lastPublishDrain = seq
    local text = mode.publish()
    if text and text ~= "" then logs.warn(text) end
end

--- 配置各列生效性（唯一判定处）
-- 阈值调度：勾选+阈值生效；速率调度：权重+增产生效，受阈值约束时勾选+阈值也生效。
-- @return table { enabled = boolean, threshold = boolean, weight = boolean, boost = boolean }
function system.effectiveConfig()
    local rate   = state.read.mode() == "rate"
    local gated  = (not rate) or (state.read.enforceThreshold() == true)
    return {
        enabled   = gated,
        threshold = gated,
        weight    = rate,
        boost     = rate
    }
end

--- 统一调度请求：运行中 -> 建议基线 -> plan
-- @param reason string
-- @return boolean
function system.requestPlan(reason)
    if not state.read.running() then return false end
    if system.checkSuggestionChange() then return false end -- 建议变：已停会话 + 等待用户
    return plan.run(reason)
end

--- 设建议基线为当前建议（启动会话调用，不触发等待）
function system.resetSuggestBaseline()
    state.write.setBaseline(power.suggestVector())
end

--- 建议相对会话基线变化 -> 停会话 + 等待用户（明细进 debug）
-- 只比整数建议；无基线只记。唯一调用者 requestPlan 已先过"运行中"闸。
-- @return boolean 是否因此进入等待（true = 调用方本轮不要再排计划）
function system.checkSuggestionChange()
    local now = power.suggestVector()
    local was = state.read.baseline()

    if not was then
        state.write.setBaseline(now)
        return false
    end

    local changed = {}
    for level = 1, constants.LEVEL_COUNT do
        local a, b = tonumber(was[level]) or 0, tonumber(now[level]) or 0
        if a ~= b then changed[#changed + 1] = { level = level, from = a, to = b } end
    end
    if #changed == 0 then return false end

    state.write.setBaseline(now)

    local texts = {}
    for _, item in ipairs(changed) do
        texts[#texts + 1] = string.format("%s %s→%s", constants.levelLabel(item.level),
            tostring(item.from), tostring(item.to))
    end
    logs.debug("建议并行变化（等待用户）：" .. table.concat(texts, "、"))

    system.enterAwaiting("建议并行已变化", true, "请按新建议调好机器并行，再点【启动系统】")
    return true
end

--- 检查"一次性提示"（阈值低于保供线 / 全 0 / 速率模式备注…）
-- 文本/指纹/整块提示由模式给；只报一次哨兵在此。
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
    state.write.setRunning(true)
    plan.forget()
    system.resetSuggestBaseline() -- 启动会话：以"当前建议"为基线（用户刚按建议调好机器才点的启动）
    logs.system("并行学习已重置（从建议值重新学习）")
end

--- 结束一次运行会话：置停止态，清学习值，忘掉旧方案
local function endSession(reason)
    state.write.setRunning(false)
    system.resetLearning(reason)
    plan.forget()
end

--- 启动（开始自动调度；等待用户的唯一手动恢复入口）
-- @param reason string
-- @return boolean 是否真的启动了
function system.start(reason)
    if state.read.running() then return true end
    if state.read.plant(constants.HOST_LEVEL).switch == false then
        logs.warn("无法启动：净水主机未开机")
        return false
    end

    logs.system(string.format("启动（%s）", tostring(reason or "-")))
    if state.read.awaiting() then
        local why = state.write.clearAwaiting()
        logs.system("已恢复（原等待原因：" .. tostring(why) .. "）")
    end
    beginSession(reason)
    system.auditThresholds()
    system.requestPlan("启动")
    return true
end

--- 停机（下发全关；正常停机不置等待）
-- @param reason string
function system.stop(reason)
    local count = actuator.shutdownAll()
    endSession(reason)
    logs.system(string.format("停机（%s）：已下发全关 %d 台", tostring(reason or "-"), count))
end

--- 等待用户（软因：人工改动 / 建议变 / 硬件变）-> 停会话 + 置等待
-- allOff = true 先全关；false 保持机器现状
-- @param why string
-- @param allOff boolean
-- @param line string|nil 进等待时的一行提示（只打这一次）
function system.enterAwaiting(why, allOff, line)
    if state.read.awaiting() then return false end
    if line then logs.warn(line) end
    if allOff then
        system.stop(why)
    else
        endSession(why)
        logs.system(string.format("停机：%s；保持现状，未下发指令", why))
    end
    state.write.setAwaiting(tostring(why or "等待处理"))
    logs.warn("等待用户处理：" .. state.read.awaitReason())
    return true
end

--- 硬因（缺件 / 主机关）：只在运行中停一次；不置等待，事实恢复即回"停机待启动"
-- @param why string
-- @return boolean 是否真的停了
local function stopIfRunning(why)
    if not state.read.running() then return false end
    system.stop(why)
    return true
end

-- 事件入口

--- 硬件缺失（电平事件）-> 运行中则全关停机；不置等待（事实恢复自动回停机）
function system.onHardwareMissing(payload)
    local what = table.concat((payload and payload.missing) or { "未知" }, "、")
    stopIfRunning("硬件缺失：" .. what)
end

--- 主机开关是关的 -> 运行中则全关停机；不置等待
function system.ensureHostStopped()
    return stopIfRunning(HOST_OFF_REASON)
end

--- 实测开关偏离方案 -> 停会话 + 等待用户，不动机器（只在运行中被接受）
function system.onSwitchMismatch(payload)
    if not payload or not payload.level then return end
    if not state.read.running() then return end
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

    system.enterAwaiting(levelName .. " 开关被人工改动", false, string.format(
        "%s 实测%s，方案要%s；点【启动系统】恢复 ｜ %s",
        levelName, payload.got and "开" or "关", payload.want and "开" or "关", sentText))
end

--- 硬件台账变化 -> 运行中：停会话 + 等待用户；非运行：只清学习
function system.onHardwareChanged()
    if state.read.running() then
        system.enterAwaiting("硬件变更", true)
    else
        system.resetLearning("硬件变更")
    end
end

--- 全厂功率变化 -> 发布建议 + 清本轮学习值，在运行中则重排
function system.onPowerChanged(payload)
    system.publish()
    system.resetLearning(string.format("功率变化 %s -> %s",
        tostring(payload and payload.from), tostring(payload and payload.to)))
    system.requestPlan("功率变化")
end

--- 台数变化（T3 写完快照后）-> 发布建议（各状态恒发，等待/停机期间也照看新建议）
function system.onDeployedChanged()
    system.publish()
end

--- 并行学习值更新 -> 重算规则并立即重排
function system.onParallelWrite(payload)
    if not payload or not learning.remember(payload.level, payload.parallel, payload.success) then
        return false
    end
    logs.system(string.format("%s 实际并行 = %s（来源：%s）",
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

--- 制作自动化（开关 / 就绪性 / 缺料）变化 -> 重判（可开启性判定里含 produce.blocked）
-- @param payload table|nil { reason }
function system.onProduceChanged(payload)
    system.requestPlan(payload and payload.reason or "制作自动化变化")
end

--- 开关系统（界面一个键搞定）
function system.toggle(reason)
    if state.read.running() then
        system.stop(reason or "手动")
        return false
    end
    system.start(reason or "手动")
    return true
end

return system
