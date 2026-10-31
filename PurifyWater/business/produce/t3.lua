-- T3 絮凝：每周期固定投 900KL 聚氯化铝。
local resources = require("shared.resources")
local machine = require("business.produce.machine")
local flow = require("business.produce.flow")

local FLUID = resources.FLUIDS.POLYALUMINIUM_CHLORIDE
local AMOUNT = 900000

local t3 = {
    level = 3,
    priority = 20,
    initial = "transfer",
}

function t3.requiredFluids() return { FLUID } end
function t3.minTransferRate() return 2621440 end

function t3.build()
    return { state = "transfer" }
end

t3.states = {
    transfer = function(task, event, _, env)
        local target = task.entry.sides and task.entry.sides.target
        local action, done = flow.fluid("io", task, event, { id = FLUID.id, label = FLUID.label },
            AMOUNT, target, env, "transfer")
        if done then return machine.done() end
        return action
    end,
}

return t3