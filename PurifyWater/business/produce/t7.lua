-- T7 脱气：控制信号解析后按需投料。
local resources = require("shared.resources")
local machine = require("business.produce.machine")
local flow = require("business.produce.flow")

local SUPERCONDUCTORS = {
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UHV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UEV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UIV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UMV.id,
}
local SUPERCOOLANT = { fluid = resources.FLUIDS.SUPERCOOLANT.id, amount = 10000, label = resources.FLUIDS.SUPERCOOLANT.label, short = resources.FLUIDS.SUPERCOOLANT.short }
local GAS_HE = { fluid = resources.FLUIDS.HELIUM.id, amount = 10000, label = resources.FLUIDS.HELIUM.label }
local GAS_NE = { fluid = resources.FLUIDS.NEON.id, amount = 7500, label = resources.FLUIDS.NEON.label }
local GAS_KR = { fluid = resources.FLUIDS.KRYPTON.id, amount = 5000, label = resources.FLUIDS.KRYPTON.label }
local GAS_XE = { fluid = resources.FLUIDS.XENON.id, amount = 2500, label = resources.FLUIDS.XENON.label }
local SUPERCONDUCTOR = { any = SUPERCONDUCTORS, amount = 1440, label = "熔融超导粗胚", short = "超导粗胚" }
local NEUTRONIUM = { fluid = resources.FLUIDS.MOLTEN_NEUTRONIUM.id, amount = 4608, label = resources.FLUIDS.MOLTEN_NEUTRONIUM.label }

local FLUIDS = {
    resources.FLUIDS.SUPERCOOLANT,
    resources.FLUIDS.HELIUM,
    { label = "熔融超导粗胚（UV-UMV 任意）", any = SUPERCONDUCTORS },
    resources.FLUIDS.NEON,
    resources.FLUIDS.MOLTEN_NEUTRONIUM,
    resources.FLUIDS.KRYPTON,
    resources.FLUIDS.XENON,
}

local t7 = {
    level = 7,
    priority = 40,
    initial = "sensor",
}

function t7.requiredFluids() return FLUIDS end
function t7.minTransferRate() return 200000 end

function t7.demand(signal)
    local n = tonumber(signal)
    if n == nil then return nil, "读不到控制信号", nil end
    if n >= 8 then return {}, nil, n end
    if n == 0 then return { SUPERCOOLANT }, nil, n end
    local out = {}
    if n % 2 == 1 then
        local gas = math.floor(n / 2) % 4
        if gas == 0 then out[#out + 1] = GAS_HE
        elseif gas == 1 then out[#out + 1] = GAS_NE
        elseif gas == 2 then out[#out + 1] = GAS_KR
        else out[#out + 1] = GAS_XE end
    end
    if math.floor(n / 2) % 2 == 1 then out[#out + 1] = SUPERCONDUCTOR end
    if math.floor(n / 4) % 2 == 1 then out[#out + 1] = NEUTRONIUM end
    return out, nil, n
end

function t7.build()
    return { state = "sensor", index = 1 }
end

t7.states = {
    sensor = function(task, event, _, _)
        if event == nil then
            return machine.command("sensor", { field = "controlSignal" }, "sensor")
        end
        if not event.ok then return machine.fail("读不到控制信号：" .. tostring(event.err)) end
        local demand, why = t7.demand(event.value)
        if not demand then return machine.fail(why) end
        if #demand == 0 then return machine.done() end
        task.needs = demand
        task.index = 1
        return machine.jump("transfer")
    end,

    transfer = function(task, event, _, env)
        local need = task.needs and task.needs[task.index]
        if not need then return machine.done() end
        local target = task.entry.sides and task.entry.sides.target
        local spec = need.fluid and { id = need.fluid, label = need.label, short = need.short }
            or { any = need.any, label = need.label, short = need.short }
        local action, done = flow.fluid("io", task, event, spec, need.amount, target, env, "transfer")
        if done then
            task.index = task.index + 1
            if task.index > #task.needs then return machine.done() end
            return machine.jump("transfer")
        end
        return action
    end,
}

return t7