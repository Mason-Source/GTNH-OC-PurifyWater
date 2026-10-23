--------------------------------------------------------------------------------
-- backend/domain/modes/rate.lua
--------------------------------------------------------------------------------
-- 【职责】速率调度模式：算账结果（domain/rates）转判定/顺序/审计
-- 【不做什么】不算数（domain/rates）、不写盘、不写日志（审计只给数据）
-- 【依赖】shared/{config,constants,state}、domain/{rules,rates}
-- 【被谁用】domain/mode（按 config.mode 分发）
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")
local utils     = require("shared.utils")

local rules     = require("backend.domain.rules")
local rates     = require("backend.domain.rates")
local produce   = require("backend.domain.produce")

local rate      = {}

--- 模式名字（界面/日志用；id 由 main 注册处给）
function rate.label() return "速率调度" end

--- 功率利用不充分警告：所需台数与现有台数
-- 所需台数ₙ = ceil(功率λ × 期望总并行ₙ ÷ 单机上限ₙ)；仅功率λ > 上限λ 时报。
-- @param plan table rates.plan() 的返回
-- @return string|nil
local function limitText(plan)
    local top   = state.serviceTop()
    local limit = plan.limit
    if top <= 0 or limit.lambdaPower <= 0 then return nil end
    if limit.lambdaCap >= limit.lambdaPower then return nil end   -- 功率是瓶颈：不报

    local need, have = {}, {}
    for level = 1, top do
        local want = plan.want[level] or 0
        local cap  = constants.parallelCap(level)
        need[#need + 1] = utils.formatShortNumber(math.ceil(limit.lambdaPower * want / cap))
        have[#have + 1] = utils.formatShortNumber(state.read.plant(level).deployed or 0)
    end

    return string.format("速率模式：功率利用不充分，建议 T1-%d 所需台数 %s，现有台数 %s",
        top, table.concat(need, " "), table.concat(have, " "))
end

--- 算一次方案并发布建议与审计明细；返回扩产建议一行（日志由 app 层打）
-- 受控点 = mode.publish()。
function rate.publish()
    local plan = rates.plan()
    for level = 1, constants.LEVEL_COUNT do
        state.write.publishSuggest(level, plan.suggest[level] or 0)
    end
    state.write.setNotes(plan.notes or {})
    return limitText(plan)
end

--- 可开启性：未部署/断点外/无需求/原料不足/制作自动化拦 -> 关；受阈值约束走水位判定。
-- @param level number
-- @return boolean
function rate.evaluate(level)
    local snap = state.read.plant(level)
    if (snap.deployed or 0) <= 0 then return false end

    -- 断点外不可达
    if state.serviceTop() < level then return false end
    -- 无需求（rates.wanted）
    if not rates.wanted(level) then return false end
    if rules.materialBlocked(level) then return false end
    -- 制作自动化拦住（启用且未就绪 / 被拦）-> 本轮不开
    if produce.blocked(level) then return false end

    if state.read.enforceThreshold() then return rules.belowThreshold(level) end
    return true
end

--- 贪心顺序：沿用持久化优先级。
-- 实测并行比建议大时功率不够开全部，需按优先级取舍。
-- @return table
function rate.order()
    return state.priorityOrder()
end

--- 审计数据（文本 + 指纹 + 整块提示；只算不写日志）
-- @return table texts        user 级（logs.warn）
-- @return string signature   指纹：文案不变就不重复报
-- @return string|nil warnText 整块提示（"全 0"/"T1 未部署"这类；只报一次）
function rate.audit()
    local texts, sigs = {}, {}

    -- 受阈值约束时沿用阈值模式提示
    if state.read.enforceThreshold() then
        local notes, sig = rules.thresholdNotes()
        for _, text in ipairs(notes) do texts[#texts + 1] = text end
        if sig ~= "" then sigs[#sigs + 1] = sig end
    end

    -- 审计明细由 publish() 发布，这里不触发算账
    for _, note in ipairs(state.read.notes() or {}) do
        local label = constants.levelLabel(note.level)
        if note.kind == "too_small" then
            texts[#texts + 1] = string.format(
                "速率模式：功率不足，%s 按比例分不到 1 并行（本轮不开）", label)
        end
        sigs[#sigs + 1] = string.format("%s:%d", note.kind, note.level)
    end

    local warnText
    if state.serviceTop() <= 0 then
        warnText = "速率模式：T1澄清 未部署，无可行方案（建议并行全 0）"
    elseif rates.allZero() then
        warnText = "速率模式：在役等级权重全为 0，无生产计划（请到配置页填权重）"
    elseif state.read.enforceThreshold() and not rules.hasPositiveThreshold() then
        warnText = "速率模式：用户阈值全为 0，按低保线执行（请到配置页设置阈值）"
    end
    return texts, table.concat(sigs, "|"), warnText
end

return rate
