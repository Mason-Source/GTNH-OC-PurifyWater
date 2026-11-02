--------------------------------------------------------------------------------
-- PurifyWater/business/produce/t5.lua
--
-- 定位：T5 等离子加热制作自动化。
-- 功能：每周期先降至安全温度，再执行三轮氦等离子加热和超级冷却液降温。
-- 边界：只读取温度和生成转运命令，不直接操作设备。
--------------------------------------------------------------------------------

local resources = require("shared.resources")
local machine = require("business.produce.machine")
local flow = require("business.produce.flow")

local PLASMA = resources.FLUIDS.HELIUM_PLASMA
local COOLANT = resources.FLUIDS.SUPERCOOLANT
local HEAT_TARGET = 10000
local MAX_TEMP = 12500
local MAX_CYCLES = 3
local PLASMA_NEED = 100
local COOLANT_NEED = 2000
local CYCLE_SETTLE = 1

local t5 = {
    level = 5,
    priority = 5,
    initial = "init",
}

--- 返回 T5 所需的氦等离子与超级冷却液。
function t5.requiredFluids() return { PLASMA, COOLANT } end

--- 创建三轮加热/冷却的 T5 任务。
function t5.build()
    return { state = "init", cycles = 0, temperature = 0 }
end

local function readTemperature(task)
    return machine.command("sensor", { field = "temperature" }, task.state)
end

local function applyTemperature(task, event)
    if not event.ok then return machine.fail("温度不可读：" .. tostring(event.err)) end
    local temperature = tonumber(event.value)
    if temperature == nil then return machine.fail("温度不是数值") end
    if temperature > MAX_TEMP then return machine.fail("温度超过安全上限") end
    task.temperature = temperature
    return nil
end

t5.states = {
    init = function(task, event, _, _)
        if event == nil then return readTemperature(task) end
        local failed = applyTemperature(task, event)
        if failed then return failed end
        if task.temperature > 0 then
            return machine.wait(task.temperature / 500, "precool_sensor")
        end
        return machine.jump("heat_start")
    end,

    precool_sensor = function(task, event, _, _)
        if event == nil then return readTemperature(task) end
        local failed = applyTemperature(task, event)
        if failed then return failed end
        if task.temperature > 0 then
            return machine.wait(task.temperature / 500, "precool_sensor")
        end
        return machine.jump("heat_start")
    end,

    heat_start = function(task, _, _, env)
        if task.cycles >= MAX_CYCLES then return machine.done() end
        local target = task.entry.sides and task.entry.sides.target
        local action = flow.fluid("heat", task, nil, { id = PLASMA.id, label = PLASMA.label },
            PLASMA_NEED, target, env, "heat_transfer")
        return action
    end,

    heat_transfer = function(task, event, _, env)
        local target = task.entry.sides and task.entry.sides.target
        local action, done = flow.fluid("heat", task, event, { id = PLASMA.id, label = PLASMA.label },
            PLASMA_NEED, target, env, "heat_transfer")
        if done then
            return machine.wait((HEAT_TARGET - math.max(0, task.temperature)) / 1000, "heat_sensor")
        end
        return action
    end,

    heat_sensor = function(task, event, _, _)
        if event == nil then return readTemperature(task) end
        local failed = applyTemperature(task, event)
        if failed then return failed end
        if task.temperature < HEAT_TARGET then
            return machine.wait((HEAT_TARGET - math.max(0, task.temperature)) / 1000, "heat_sensor")
        end
        return machine.jump("cool_start")
    end,

    cool_start = function(task, _, _, env)
        local target = task.entry.sides and task.entry.sides.target
        local action = flow.fluid("cool", task, nil, { id = COOLANT.id, label = COOLANT.label },
            COOLANT_NEED, target, env, "cool_transfer")
        return action
    end,

    cool_transfer = function(task, event, _, env)
        local target = task.entry.sides and task.entry.sides.target
        local action, done = flow.fluid("cool", task, event, { id = COOLANT.id, label = COOLANT.label },
            COOLANT_NEED, target, env, "cool_transfer")
        if done then
            return machine.wait(math.max(0.05, task.temperature / 500), "cool_sensor")
        end
        return action
    end,

    cool_sensor = function(task, event, _, _)
        if event == nil then return readTemperature(task) end
        local failed = applyTemperature(task, event)
        if failed then return failed end
        if task.temperature > 0 then
            return machine.wait(math.max(0.05, task.temperature / 500), "cool_sensor")
        end
        return machine.wait(CYCLE_SETTLE, "settle")
    end,

    settle = function(task, _, _, _)
        task.cycles = task.cycles + 1
        return machine.jump("heat_start")
    end,
}

return t5