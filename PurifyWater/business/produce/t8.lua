-- T8 萃取：按最短覆盖路径逐周期投 18 枚夸克释放催化剂。
local resources = require("shared.resources")
local machine = require("business.produce.machine")
local flow = require("business.produce.flow")

local CATALYSTS = {
    resources.ITEMS.QUARK_UP_CATALYST,
    resources.ITEMS.QUARK_DOWN_CATALYST,
    resources.ITEMS.QUARK_STRANGE_CATALYST,
    resources.ITEMS.QUARK_CHARM_CATALYST,
    resources.ITEMS.QUARK_BOTTOM_CATALYST,
    resources.ITEMS.QUARK_TOP_CATALYST,
}
local WALK = { 1, 2, 3, 4, 5, 6, 2, 4, 6, 1, 3, 5, 1, 4, 6, 3, 2, 5 }
local SETTLE_SECONDS = 2

local t8 = {
    level = 8,
    priority = 10,
    initial = "sensor",
}

function t8.requiredItems() return CATALYSTS end

local function toPercent(value)
    value = tonumber(value)
    if value == nil then return nil end
    if value <= 1 then value = value * 100 end
    return value
end

function t8.build()
    return { state = "sensor", index = 1, first = true }
end

t8.states = {
    sensor = function(task, event, _, _)
        if event == nil then
            return machine.command("sensor", { field = "success" }, "sensor")
        end
        if not event.ok then return machine.fail("成功率不可读：" .. tostring(event.err)) end
        local success = toPercent(event.value)
        if success == nil then return machine.fail("成功率不是数值") end
        if success >= 99.5 then return machine.done() end
        if task.first then
            task.first = false
            task.index = 1
        else
            task.index = task.index + 1
            if task.index > #WALK then return machine.fail("18 枚催化剂已投完，但成功率未达到 100%") end
        end
        return machine.jump("transfer")
    end,

    transfer = function(task, event, _, _)
        local item = CATALYSTS[WALK[task.index]]
        local target = task.entry.sides and task.entry.sides.itemTarget
        local action, done = flow.item("io", task, event, item, 1, target, "transfer")
        if done then return machine.wait(SETTLE_SECONDS, "sensor") end
        return action
    end,
}

return t8