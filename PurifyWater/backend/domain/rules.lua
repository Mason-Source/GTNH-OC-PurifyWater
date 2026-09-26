--------------------------------------------------------------------------------
-- backend/domain/rules.lua
--------------------------------------------------------------------------------
-- 【职责】"这一级水厂该不该开"的**全部判定**（纯函数：只读 state 快照，不读盘、不碰机器）
-- 【依赖】shared/constants、shared/utils、shared/state、backend/domain/power
-- 【被谁用】domain/allocator（每轮调度）、app/watch（水位变化时预判并广播 level_openable_changed）
--
-- 【判定，从上到下短路】
--   ① 原料不足：本级 > 1，且上一级水 < 本级 N 倍线        -> 禁止
--   ② 水位 < 实际执行阈值                                -> 开启
--   ③ 否则                                               -> 关闭
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
-- @return table { own, next, user, actual, fromNext, overridden }
function rules.lines(level)
    local rule = state.rules[level]
    local user = 0
    if rule and rule.enabled and (rule.threshold or 0) > 0 then
        user = rule.threshold
    end

    local own  = rules.reserveLine(level)
    local next = 0
    if level < constants.LEVEL_COUNT then
        next = rules.reserveLine(level + 1)
    end

    return {
        own        = own,
        next       = next,
        user       = user,
        actual     = math.max(user, next),
        fromNext   = next > user,
        overridden = user > 0 and user < next
    }
end

--- 可开启性判定（纯函数）
-- @param level number 1..LEVEL_COUNT
-- @return table { open = boolean, forced = boolean, reason = string }
function rules.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then
        return { open = false, forced = false, reason = "未部署机器" }
    end

    local own = state.fluids[level]
    local line = rules.lines(level)

    -- ① 原料不足：上一级的水不够本级用
    if level > 1 then
        local prev = state.fluids[level - 1]
        if prev < line.own then
            return {
                open = false,
                forced = false,
                reason = string.format(
                    "原料不足：%s 仅 %s，需 %s",
                    constants.levelLabel(level - 1),
                    utils.formatShortNumber(prev), utils.formatShortNumber(line.own))
            }
        end
    end

    -- ② 实际执行阈值 = max(用户阈值, 下一级 N 倍线)
    if own < line.actual then
        local why = line.fromNext
            and ("保供下一级：低于 5 倍线 " .. utils.formatShortNumber(line.next))
            or ("低于阈值：低于 " .. utils.formatShortNumber(line.actual))
        return {
            open = true,
            forced = line.fromNext,
            reason = string.format("%s（本级 %s）", why, utils.formatShortNumber(own))
        }
    end

    -- ③ 达到实际阈值 -> 关闭
    return {
        open = false,
        forced = false,
        reason = string.format(
            "已达实际阈值：%s / %s",
            utils.formatShortNumber(own), utils.formatShortNumber(line.actual))
    }
end

--- 重判全部等级并写回快照（阈值、功率、学习值变化后调用）
function rules.refreshAll()
    for level = 1, constants.LEVEL_COUNT do
        local verdict                           = rules.evaluate(level)
        local snap                              = state.plant(level)
        snap.openable, snap.forced, snap.reason = verdict.open, verdict.forced, verdict.reason
    end
end

return rules
