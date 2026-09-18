--------------------------------------------------------------------------------
-- backend/domain/allocator.lua
--------------------------------------------------------------------------------
-- 【职责】按优先级做一轮**贪心调度**：预算够就开、不够就关，并给出每级的理由
-- 【依赖】shared/state、domain/rules、domain/power
-- 【被谁用】backend/app/plan（唯一调度入口）
--
-- 【算法】按 state.priorityOrder() 的顺序（两种运行模式只差这个顺序）逐级：
--   规则说不能开              -> 关（理由来自 rules）
--   规则说能开但剩余预算不够   -> 关（理由 = 功率不足：需 X / 剩 Y）
--   否则                     -> 开，并从剩余预算里扣掉这一级的功耗
-- 副产物：把 openable / forced / reason 写回 state.plants[level] 供界面显示
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local utils     = require("shared.utils")
local state     = require("shared.state")
local power     = require("backend.domain.power")
local rules     = require("backend.domain.rules")

local allocator = {}

--- 算一轮方案
-- @param order table|nil 等级顺序（默认按当前优先级）
-- @return table { plan = {[level]=boolean}, reasons = {[level]=string}, used = number,
--                 budget = number, opened = table(等级数组), warn = string|nil }
function allocator.plan(order)
    order           = order or state.priorityOrder()
    local budget    = state.power.all or 0
    local remaining = budget
    local result    = { plan = {}, reasons = {}, used = 0, budget = budget, opened = {}, warn = nil }

    if budget <= 0 then
        result.warn = "[警告] 全厂可用功率为 0（能量仓没读到？）—— 本轮不开启任何等级"
    end

    for _, level in ipairs(order) do
        local verdict      = rules.evaluate(level)
        local cost         = power.levelPower(level)
        local open, reason = verdict.open, verdict.reason

        if open and cost > remaining then
            open   = false
            reason = string.format("功率不足：需 %s，剩 %s",
                utils.formatShortNumber(cost), utils.formatShortNumber(remaining))
        end

        result.plan[level]    = open
        result.reasons[level] = reason
        if open then
            remaining = remaining - cost
            result.opened[#result.opened + 1] = level
        end

        -- 写回快照，界面/日志统一读这一处
        local snap    = state.plant(level)
        snap.openable = verdict.open
        snap.forced   = verdict.forced
        snap.reason   = reason
    end

    result.used = budget - remaining
    state.power.budget = remaining
    return result
end

--- 两套方案是否完全一样（用于避免重复下发）
-- @param a table
-- @param b table
-- @return boolean
function allocator.isSame(a, b)
    if not a or not b then return false end
    for level = 1, constants.LEVEL_COUNT do
        if (a[level] == true) ~= (b[level] == true) then return false end
    end
    return true
end

--- 方案 -> 一行文字（只给调度日志用）
-- 【为什么只写 T 号】8 级同时开时，带中文名的 label 拼起来能到 60 多列，把日志面板整个冲掉；
--   这里只写 `开 T1 T3 ｜ 关 T2 T4`；全关/全开就不重复列另一组。
-- @param plan table
-- @return string
function allocator.describe(plan)
    local on, off = {}, {}
    for level = 1, constants.LEVEL_COUNT do
        local list = plan[level] and on or off
        list[#list + 1] = "T" .. level
    end
    if #on == 0 then return "全关" end
    if #off == 0 then return "开 " .. table.concat(on, " ") end
    return "开 " .. table.concat(on, " ") .. " ｜ 关 " .. table.concat(off, " ")
end

return allocator
