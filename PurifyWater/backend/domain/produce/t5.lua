--------------------------------------------------------------------------------
-- backend/domain/produce/t5.lua
--------------------------------------------------------------------------------
-- 【职责】T5（等离子加热）制作自动化方法：只读温度并完成 3 次加热/冷却
-- 【不做什么】不碰组件、不写状态；等待和动作都由 operation ctx 异步执行
-- 【依赖】无
-- 【被谁用】main.lua（注册到 backend/domain/produce）、produce_job（执行）
--
-- 【机器机制】每个主周期从 0K 开始：
--   100mB helium plasma -> +10,000K；2000mB supercoolant -> 回 0K。
--   重复 3 次完成本轮；超过 12,500K 失败。
--
-- 【简化】不再依赖 heating_cycles 字段。operation 自己在本地计数 3 次，
--   每次降到 0K 后固定等待 1 秒让机器结算，再进入下一次加热。
--------------------------------------------------------------------------------

local t5 = {}

local PLASMA       = "plasma.helium"
local COOLANT      = "supercoolant"
local HEAT_TARGET  = 10000
local MAX_TEMP     = 12500
local MAX_CYCLES   = 3
local PLASMA_NEED  = 100
local COOLANT_NEED = 2000
local CYCLE_SETTLE = 1

t5.PLASMA       = PLASMA
t5.COOLANT      = COOLANT
t5.HEAT_TARGET  = HEAT_TARGET
t5.MAX_TEMP     = MAX_TEMP
t5.MAX_CYCLES   = MAX_CYCLES
t5.PLASMA_NEED  = PLASMA_NEED
t5.COOLANT_NEED = COOLANT_NEED
t5.priority     = 5  -- 全链路最高优先级

local FLUIDS = { PLASMA, COOLANT }
local STOCK  = {
    { fluid = PLASMA, amount = PLASMA_NEED, label = "氦等离子" },
    { fluid = COOLANT, amount = COOLANT_NEED, label = "超级冷却液" }
}

function t5.requiredFluids() return FLUIDS end
function t5.stockRequirements() return STOCK end
function t5.need() return {}, nil, nil end

local function readTemperature(ctx)
    local temperature, err = ctx.sensorInfo("temperature")
    if temperature == nil then return nil, tostring(err or "温度不可读") end
    return temperature, nil
end

--- 等待升温到目标
local function waitHeat(ctx, temperature)
    while temperature < HEAT_TARGET do
        if temperature > MAX_TEMP then return nil, "温度超过安全上限" end
        if not ctx.active() then return nil, "机器 active=false" end
        ctx.wait((HEAT_TARGET - math.max(0, temperature)) / 1000)
        local err
        temperature, err = readTemperature(ctx)
        if temperature == nil then return nil, err end
    end
    return temperature, nil
end

--- 等待降温到 0K
local function waitCool(ctx, temperature)
    while temperature > 0 do
        if temperature > MAX_TEMP then return nil, "温度超过安全上限" end
        if not ctx.active() then return nil, "机器 active=false" end
        ctx.wait(temperature / 500)
        local err
        temperature, err = readTemperature(ctx)
        if temperature == nil then return nil, err end
    end
    return temperature, nil
end

--- 一个主周期内执行 3 次完整加热/冷却
function t5.operation(ctx)
    local temperature, err = readTemperature(ctx)
    if temperature == nil then return false, err end
    if temperature > MAX_TEMP then return false, "温度超过安全上限" end
    if not ctx.active() then return false, "机器 active=false" end

    -- 周期起点理论上为 0K；若任务起飞略晚且仍有残温，先降到 0K 再开始。
    if temperature > 0 then
        temperature, err = waitCool(ctx, temperature)
        if temperature == nil then return false, err end
    end

    for _ = 1, MAX_CYCLES do
        if not ctx.active() then return false, "机器 active=false" end
        local ok, why = ctx.transferFluid(PLASMA, PLASMA_NEED)
        if not ok then return false, why end
        temperature, err = waitHeat(ctx, temperature)
        if temperature == nil then return false, err end

        if not ctx.active() then return false, "机器 active=false" end
        ok, why = ctx.transferFluid(COOLANT, COOLANT_NEED)
        if not ok then return false, why end
        temperature, err = waitCool(ctx, temperature)
        if temperature == nil then return false, err end

        -- 温度已经归零；给机器一个结算窗口，避免下一份等离子抢先进入。
        ctx.wait(CYCLE_SETTLE)
    end

    return true
end

return t5
