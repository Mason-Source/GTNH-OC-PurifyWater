-- T4 pH 调节：读 pH，补氢氧化钠粉或氢氯酸。
local resources = require("shared.resources")
local machine = require("business.produce.machine")
local flow = require("business.produce.flow")

local ACID = resources.FLUIDS.HYDROCHLORIC_ACID
local ALKALINE = resources.ITEMS.SODIUM_HYDROXIDE_DUST
local PH_TARGET = 7
local PH_TOLERANCE = 0.05
local PH_PER_DUST = 0.01
local PH_PER_10_ACID = 0.01
local MAX_DUST = 250
local MAX_ACID = 2500

local t4 = {
    level = 4,
    priority = 30,
    initial = "sensor",
}

function t4.requiredFluids() return { ACID } end
function t4.requiredItems() return { ALKALINE } end
function t4.minTransferRate() return 50000 end

function t4.demand(ph)
    ph = tonumber(ph)
    if ph == nil then return nil, "读不到 pH", nil end
    if ph <= 0 then return nil, "pH 尚未初始化", ph end
    local errorValue = PH_TARGET - ph
    if math.abs(errorValue) <= PH_TOLERANCE then return {}, nil, ph end
    if errorValue > 0 then
        local count = math.min(MAX_DUST, math.floor(errorValue / PH_PER_DUST + 0.5))
        return { { item = ALKALINE, amount = count, label = ALKALINE.label } }, nil, ph
    end
    local doses = math.floor((-errorValue) / PH_PER_10_ACID + 0.5)
    local amount = math.min(MAX_ACID, doses * 10)
    return { { fluid = ACID.id, amount = amount, label = ACID.label } }, nil, ph
end

function t4.build()
    return { state = "sensor" }
end

t4.states = {
    sensor = function(task, event, _, _)
        if event == nil then
            return machine.command("sensor", { field = "ph" }, "sensor")
        end
        if not event.ok then return machine.fail("读不到 pH：" .. tostring(event.err)) end
        local demand, why = t4.demand(event.value)
        if not demand then return machine.fail(why) end
        if #demand == 0 then return machine.done() end
        task.need = demand[1]
        return machine.jump("transfer")
    end,

    transfer = function(task, event, _, env)
        local need = task.need
        if not need then return machine.fail("T4 缺少 pH 调节需求") end
        local sides = task.entry.sides or {}
        local action, done
        if need.item then
            action, done = flow.item("io", task, event, need.item, need.amount,
                sides.itemTarget, "transfer")
        else
            action, done = flow.fluid("io", task, event, { id = need.fluid, label = need.label },
                need.amount, sides.target, env, "transfer")
        end
        if done then return machine.done() end
        return action
    end,
}

return t4