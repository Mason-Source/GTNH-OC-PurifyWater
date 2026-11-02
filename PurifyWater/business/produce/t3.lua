--------------------------------------------------------------------------------
-- PurifyWater/business/produce/t3.lua
--
-- 定位：T3 絮凝制作自动化。
-- 功能：每周期向絮凝机固定转运 900,000 L 聚氯化铝，并复用通用流体子流程。
-- 边界：只定义需求和状态，不直接访问组件。
--------------------------------------------------------------------------------

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

--- 返回 T3 所需的聚氯化铝流体。
function t3.requiredFluids() return { FLUID } end
--- 返回 T3 自动转运的最低速率要求。
function t3.minTransferRate() return 2621440 end

--- 创建 T3 每周期固定投料任务。
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