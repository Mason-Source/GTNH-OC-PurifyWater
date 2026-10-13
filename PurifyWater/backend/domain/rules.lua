--------------------------------------------------------------------------------
-- backend/domain/rules.lua
--------------------------------------------------------------------------------
-- 【职责】水位线几何与两套模式共用判定：保供线/实际阈值/原料保护/水位判定/阈值提示
-- 【不做什么】不选策略（modes/*）、不写快照、不写日志
-- 【依赖】shared/{constants,state,utils}、backend/domain/power
-- 【被谁用】domain/modes/{threshold,rate}（判定 + 审计）、api.read.levels（界面显示）
--
-- 两条线：own = 本级线（查上一级供料）；next = 下一级线。
-- actual = max(用户阈值, next)：上一级补料目标自然覆盖下一级原料要求。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local utils     = require("shared.utils")
local state     = require("shared.state")
local power     = require("backend.domain.power")

local rules     = {}

--- 该等级的"保留水位线" = 5 × 该级总并行 × 每并行耗水量
-- 用途：本级 > 1 时检查上一级供料
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
    local rule = state.read.rules()[level]
    local user = 0
    if rule and rule.enabled and (rule.threshold or 0) > 0 then
        user = rule.threshold
    end

    -- 变量名避开标准库 next()
    local nextLine = 0
    if level < constants.LEVEL_COUNT then
        nextLine = rules.reserveLine(level + 1)
    end

    return {
        next       = nextLine,   -- 对外字段名保持 next
        user       = user,
        actual     = math.max(user, nextLine),
        overridden = user > 0 and user < nextLine
    }
end

--- 原料保护：上一级水不足本级开一个周期 -> true（只回布尔）
-- @param level number
-- @return boolean
function rules.materialBlocked(level)
    if level <= 1 then return false end
    return state.read.fluids()[level - 1] < rules.reserveLine(level)
end

--- 水位判定：水位 < 实际执行阈值 -> true（两模式共用）
-- @param level number
-- @return boolean
function rules.belowThreshold(level)
    return state.read.fluids()[level] < rules.lines(level).actual
end

--- 在役等级是否有正用户阈值（判"全 0"用）
-- 只看在役前缀：未部署等级的预填阈值不掩盖提示
-- @return boolean
function rules.hasPositiveThreshold()
    for level = 1, state.serviceTop() do
        local rule = state.read.rules()[level]
        if rule and (rule.threshold or 0) > 0 then return true end
    end
    return false
end

--- 阈值低于保供线的提示文本 + 指纹（只算不写日志）
-- 只看在役前缀，未部署等级不参与、不报警
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
