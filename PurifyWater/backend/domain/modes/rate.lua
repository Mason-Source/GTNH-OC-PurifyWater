--------------------------------------------------------------------------------
-- backend/domain/modes/rate.lua
--------------------------------------------------------------------------------
-- 【职责】"速率调度"模式：把权重方案的算账结果（domain/rates）变成**判定/顺序/审计**
--   建议并行 = rates.plan() 的算账结果，由 publish() 发布到 state（读侧只读 state）
--   可开启性 = 未部署 -> 无需求 -> 原料保护 -> 受阈值约束时走水位判定，不受则原料够就开
--   顺序     = 沿用持久化的优先级（只在"实测功耗 > 建议、功率不够开全部"时才用得上）
--   审计     = 受约束时的"用户阈值低于保供线"提示 + 速率自己的备注（分不到 1 并行 / 被上限夹取 / 权重全 0）
-- 【不做什么】不算数（domain/rates）、不写盘、不写日志（审计只给数据，日志在 app/system）
-- 【依赖】shared/{config,constants,state}、domain/{rules,rates}
-- 【被谁用】domain/mode（按 state.system.mode 分发）
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")
local utils     = require("shared.utils")

local rules     = require("backend.domain.rules")
local rates     = require("backend.domain.rates")

local rate      = {}

--- 模式名字（界面/日志用；id 由 main 注册处给）
function rate.label() return "速率调度" end

--- "功率利用不充分"警告：所需台数（= 用满功率需要几台）与现有台数
-- 【口径】所需台数ₙ = ceil(功率λ × 期望总并行ₙ ÷ 单机上限ₙ)
-- 【唯一条件】功率λ > 上限λ —— 即"功率有富余、却被单机上限卡住"；
--   此时必然至少一级"所需台数 > 现有台数"（同一个不等式的两边），不需要再判一次台数。
-- 【顶替】原来审计里那句"Tn 已达单机并行上限，整体并行由它决定"。
-- 【每次生成都出】发布是受控点触发（次数少），由 app 层直接 logs.warn，不参与"文本相同只报一次"。
-- @param plan table rates.plan() 的返回
-- @return string|nil
local function limitText(plan)
    local top   = state.serviceTop()
    local limit = plan.limit
    if top <= 0 or limit.lambdaPower <= 0 then return nil end
    if limit.lambdaCap >= limit.lambdaPower then return nil end   -- 功率才是瓶颈：不报（加机器没用）

    local need, have = {}, {}
    for level = 1, top do
        local want = plan.want[level] or 0
        local cap  = constants.parallelCap(level)
        need[#need + 1] = utils.formatShortNumber(math.ceil(limit.lambdaPower * want / cap))
        have[#have + 1] = utils.formatShortNumber(state.plant(level).deployed or 0)
    end

    return string.format("速率模式：功率利用不充分，建议 T1-%d 所需台数 %s，现有台数 %s",
        top, table.concat(need, " "), table.concat(have, " "))
end

--- 发布：算一次速率方案，把"每级建议并行"与审计明细写进 state（读侧只读 state）；
--   返回"扩产建议"一行（无方案 = nil）—— 由 app/system 打日志，模式层自己不写日志
-- 【唯一调用点】mode.publish()（受控触发：启动 / 功率变 / 台数变 / 权重·倍率变 / 模式切换）
function rate.publish()
    local plan = rates.plan()
    for level = 1, constants.LEVEL_COUNT do
        state.plant(level).suggest = plan.suggest[level] or 0
    end
    state.planNotes = plan.notes or {}
    return limitText(plan)
end

--- 可开启性判定
--   ① 未部署机器        -> 关
--   ② 在役前缀之外（上游有断点）-> 关（它物理上跑不起来，不该被要求任何并行）
--   ③ 本级与下游都不需要 -> 关（权重 0 且需求 0）
--   ④ 原料不足          -> 关（文案与阈值模式同一份）
--   ⑤ 受阈值约束 = 开    -> 复用阈值模式的水位判定；= 关 -> 原料够就开
-- @param level number
-- @return table { open, forced, reason }
function rate.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then return false end

    -- 在役前缀只到 T_top：本级（以及更高级）暂时不可达 —— 上游没有水，跑不起来
    if state.serviceTop() < level then return false end
    -- 权重 0 且下游也不需要 -> 无需求（等价现推，见 domain/rates.wanted）
    if not rates.wanted(level) then return false end
    if rules.materialBlocked(level) then return false end

    if state.system.enforceThreshold then return rules.belowThreshold(level) end
    return true
end

--- 贪心顺序：沿用持久化的优先级
-- 【为什么还需要顺序】方案按建议并行算出来时总功耗 ≤ 全厂功率；但机器实际并行由玩家设置，
--   实测比建议大时功率会不够开全部 —— 这时按优先级逐个取舍（与阈值模式同一套贪心）。
-- @return table
function rate.order()
    return state.priorityOrder()
end

--- 审计数据（文本 + 指纹 + 整块提示 + debug 文本；只算不写日志）
-- @return table texts        user 级（logs.warn）
-- @return string signature   指纹：文案不变就不重复报
-- @return string|nil warnText 整块提示（"全 0"/"T1 未部署"这类；只报一次）
-- @return table debugTexts   debug 级明细（取整收紧这类，不刷 user）
function rate.audit()
    local texts, sigs, debugTexts = {}, {}, {}

    -- 受阈值约束时，"用户阈值低于保供线"的提示仍然有效（与阈值模式共用文本）
    if state.system.enforceThreshold then
        local notes, sig = rules.thresholdNotes()
        for _, text in ipairs(notes) do texts[#texts + 1] = text end
        if sig ~= "" then sigs[#sigs + 1] = sig end
    end

    -- 审计明细由 rate.publish() 随方案一起发布（这里不再触发算账）
    for _, note in ipairs(state.planNotes or {}) do
        local label = constants.levelLabel(note.level)
        if note.kind == "too_small" then
            texts[#texts + 1] = string.format(
                "速率模式：功率不足，%s 按比例分不到 1 并行（本轮不开）", label)
        elseif note.kind == "clip" then
            texts[#texts + 1] = string.format(
                "速率模式：%s 建议并行被单机上限夹取（比例会失真）", label)
        elseif note.kind == "trimmed" then
            -- 只进 debug：下游被上游供给收紧（取整层面），不必刷 user
            debugTexts[#debugTexts + 1] = string.format(
                "[调试] 速率模式：%s 建议并行 %s → %s（上游 %s 只够供这么多，避免抽干它）",
                label, tostring(note.from), tostring(note.to),
                constants.levelLabel(math.max(1, note.level - 1)))
        end
        sigs[#sigs + 1] = string.format("%s:%d", note.kind, note.level)
    end

    local warnText
    if state.serviceTop() <= 0 then
        warnText = "速率模式：T1澄清 未部署，无可行方案（建议并行全 0）"
    elseif rates.allZero() then
        warnText = "速率模式：在役等级权重全为 0，无生产计划（请到配置页填权重）"
    elseif state.system.enforceThreshold and not rules.hasPositiveThreshold() then
        warnText = "所有等级的用户阈值均为 0，暂按低保线执行；请前往【配置】页面设置阈值"
    end
    return texts, table.concat(sigs, "|"), warnText, debugTexts
end

return rate
