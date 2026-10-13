local constants = require("shared.constants")
local state     = require("shared.state")
local power     = require("backend.domain.power")
local mode      = require("backend.domain.mode")
local allocator = {}
function allocator.plan(order)
    order           = order or mode.order()
    local budget    = state.read.powerAll()
    local remaining = budget
    local result    = { plan = {}, used = 0, budget = budget, opened = {}, warn = nil }
    if budget <= 0 then
        result.warn = "[警告] 全厂可用功率为 0，本轮全部关闭"
    end
    for _, level in ipairs(order) do
        local open = mode.evaluate(level)
        local cost = power.levelPower(level)
        if open and cost > remaining then open = false end
        result.plan[level] = open
        if open then
            remaining = remaining - cost
            result.opened[#result.opened + 1] = level
        end
    end
    result.used = budget - remaining
    state.write.setBudget(remaining)
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
