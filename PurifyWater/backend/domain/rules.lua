--------------------------------------------------------------------------------
-- backend/domain/rules.lua
--------------------------------------------------------------------------------
-- 【职责】"这一级水厂该不该开"的**全部判定**（纯函数：只读 state 快照，不读盘、不碰机器）
-- 【依赖】shared/constants、shared/utils、shared/state、backend/domain/power
-- 【被谁用】domain/allocator（每轮调度）、app/watch（水位变化时预判并广播 level_openable_changed）
--
-- 【三层判定，从上到下短路】
--   ① 原料不足：本级 > 1，且上一级水 < 本级 5 倍线        -> 禁止（哪怕自己已见底）
--   ② 自身水位 < 本级 5 倍线                              -> **强制开启**（不受阈值/勾选限制）
--   ③ 阈值 + 勾选：勾了 且 水位 < 阈值                     -> 开启；否则关闭
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
-- 用途：① 别把上一级抽干（否则上一级自己会原料不足停机）
--       ② 自己低于这条线 = 快见底 -> 强制开启
-- @param level number
-- @return number mB
function rules.reserveLine(level)
    return constants.OPEN_RESERVE_MULTIPLIER * power.levelParallel(level)
        * constants.STOCK_PER_PARALLEL
end

--- 可开启性判定（纯函数）
-- @param level number 1..LEVEL_COUNT
-- @return table { open = boolean, forced = boolean, reason = string }
function rules.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then
        return { open = false, forced = false, reason = "未部署机器" }
    end

    -- 【前提】state.fluids 恒为数字：T2 在**注册时就跑过一次**，且读不到按 0 写（见 jobs.readFluids）。
    --   所以这里不再有"水位读不到"那种分支 —— 读不到 = 0，判定的自然结果就是
    --   "只强开 T1、L2-T8 被原料线挡住"，本身就是安全退化。
    local own = state.fluids[level]
    local line = rules.reserveLine(level)

    -- ① 原料不足：上一级的水不够本级用
    if level > 1 then
        local prev = state.fluids[level - 1]
        if prev < line then
            return {
                open = false,
                forced = false,
                reason = string.format(
                    "原料不足：%s 仅 %s，需 %s",
                    constants.levelLabel(level - 1),
                    utils.formatShortNumber(prev), utils.formatShortNumber(line))
            }
        end
    end

    -- ② 自己见底 -> 强制开启
    if own < line then
        return {
            open = true,
            forced = true,
            reason = string.format(
                "强制：本级 %s 低于 5 倍线 %s",
                utils.formatShortNumber(own), utils.formatShortNumber(line))
        }
    end

    -- ③ 阈值 + 勾选（配置来自 data/levels.txt）
    local rule = state.rules[level]
    if not rule then
        return { open = false, forced = false, reason = "无阈值配置（文件缺失）" }
    end
    if not rule.enabled then
        return { open = false, forced = false, reason = "未勾选（不受阈值管理）" }
    end
    local threshold = rule.threshold or 0
    -- 阈值 0 = 没设阈值（新装默认）：不因阈值开启，等用户在配置页自己填
    if threshold <= 0 then
        return { open = false, forced = false, reason = "未设阈值（0）：不开启" }
    end
    if own >= threshold then
        return {
            open = false,
            forced = false,
            reason = string.format(
                "已到阈值：%s / %s",
                utils.formatShortNumber(own), utils.formatShortNumber(threshold))
        }
    end
    return {
        open = true,
        forced = false,
        reason = string.format(
            "低于阈值：%s / %s",
            utils.formatShortNumber(own), utils.formatShortNumber(threshold))
    }
end

return rules
