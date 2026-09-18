local constants = require("shared.constants")
local utils     = require("shared.utils")
local state     = require("shared.state")
local power     = require("backend.domain.power")
local rules     = require("backend.domain.rules")
local allocator = {}
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
        local snap    = state.plant(level)
        snap.openable = verdict.open
        snap.forced   = verdict.forced
        snap.reason   = reason
    end
    result.used = budget - remaining
    state.power.budget = remaining
    return result
end
function allocator.isSame(a, b)
    if not a or not b then return false end
    for level = 1, constants.LEVEL_COUNT do
        if (a[level] == true) ~= (b[level] == true) then return false end
    end
    return true
end
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
