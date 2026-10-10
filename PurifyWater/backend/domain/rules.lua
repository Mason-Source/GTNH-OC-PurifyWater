--------------------------------------------------------------------------------
-- backend/domain/rules.lua
--------------------------------------------------------------------------------
-- 【职责】**水位线几何 + 两套模式共用的判定零件**：
--   reserveLine/lines = 5 倍保供线与实际执行阈值；materialBlocked = 原料保护；
--   belowThreshold = 水位判定；thresholdNotes = "用户阈值低于保供线"的提示文本。
-- 【不做什么】不选策略（"哪套判定生效"归 domain/modes/*）、不写快照、不写日志
-- 【依赖】shared/{constants,state,utils}、backend/domain/power
-- 【被谁用】domain/modes/{threshold,rate}（判定 + 审计）、api.read.levels（界面显示）
--
-- 【两个 N 倍线】
--   own  = 本级 N 倍线，只用于检查上一级是否有足够原料
--   next = 下一级 N 倍线，与用户阈值共同组成本级实际执行阈值
--
--   actual = max(用户阈值, next)
--
--   这样上一级的补料目标天然覆盖下一级的原料要求，不会形成级间互锁。
--
--   同名逻辑在 v2 里散在三处（EX.PLANT_ORDER + canOpen + 强制层），这里只写一遍；
--   配置唯一来源是 state.rules（来自 store/levels_config）。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local utils     = require("shared.utils")
local state     = require("shared.state")
local power     = require("backend.domain.power")

local rules     = {}

--- 该等级的"保留水位线" = 5 × 该级总并行 × 每并行耗水量
-- 用途：本级 > 1 时，检查上一级是否足够给本级供料
-- @param level number
-- @return number mB
function rules.reserveLine(level)
    return constants.OPEN_RESERVE_MULTIPLIER * power.levelParallel(level)
        * constants.STOCK_PER_PARALLEL
end

--- 该级实际执行阈值及来源
-- @param level number
-- @return table { next, user, actual, overridden }
function rules.lines(level)
    local rule = state.rules[level]
    local user = 0
    if rule and rule.enabled and (rule.threshold or 0) > 0 then
        user = rule.threshold
    end

    -- 【变量别叫 next】那是标准库函数名，遮住之后本函数里就再也调不了 next()（同类坑见 settings.setMany）
    local nextLine = 0
    if level < constants.LEVEL_COUNT then
        nextLine = rules.reserveLine(level + 1)
    end

    return {
        next       = nextLine,   -- 对外字段名保持 next 不变
        user       = user,
        actual     = math.max(user, nextLine),
        overridden = user > 0 and user < nextLine
    }
end

--- 原料保护：上一级水不足本级开一个周期 -> true
-- 【两套模式共用】只回布尔：判定理由不上屏、不进日志
-- @param level number
-- @return boolean
function rules.materialBlocked(level)
    if level <= 1 then return false end
    return state.fluids[level - 1] < rules.reserveLine(level)
end

--- 水位判定（假定"已部署 + 原料够"）：水位 < 实际执行阈值 -> true
-- 【两套模式共用】速率模式"受阈值约束"时用的就是这一份
-- @param level number
-- @return boolean
function rules.belowThreshold(level)
    return state.fluids[level] < rules.lines(level).actual
end

--- 有没有任何**在役**等级设了正的"用户阈值"（判断"全 0"用；两套模式共用）
-- 【只看在役前缀】预填给未部署等级的高阈值不该掩盖"在役等级全是 0 阈值"的提示
-- @return boolean
function rules.hasPositiveThreshold()
    for level = 1, state.serviceTop() do
        local rule = state.rules[level]
        if rule and (rule.threshold or 0) > 0 then return true end
    end
    return false
end

--- "用户阈值低于保供线"的提示文本 + 指纹（只算不写日志；两套模式共用）
-- 【只看在役前缀】未部署等级（预填 / 正在接硬件造成的断点之后）不参与、不报警
-- @return table texts
-- @return string signature
function rules.thresholdNotes()
    local texts, sig = {}, {}
    for level = 1, state.serviceTop() do
        local line = rules.lines(level)
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
    return texts, table.concat(sig, "|")
end

return rules
