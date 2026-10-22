--------------------------------------------------------------------------------
-- backend/domain/produce/t7.lua
--------------------------------------------------------------------------------
-- 【职责】T7（脱气）制作自动化方法：控制信号 → 本轮需求（位规则）
-- 【不做什么】不碰组件、不写状态、不做转运
-- 【依赖】shared/resources
-- 【被谁用】main.lua（注册到 backend/domain/produce）
--
-- 【控制信号位规则】（行尾二进制串；低位权重 1）
--   位1(1)  稀有气体：种类 = 位2-3（0 氦 10000 / 1 氖 7500 / 2 氪 5000 / 3 氙 2500）
--   位2(2)  熔融超导粗胚 1440L（具体款按输入侧实有解析）
--   位3(4)  熔融中子 4608L
--   位4(8)  忽略全部位，不投
--   0       超级冷却液 10000L（实测：无任何位返回 0，不是空）

--------------------------------------------------------------------------------

local resources = require("shared.resources")

local t7 = {}

-- 熔融超导粗胚：UV-UMV 任意一种都算满足
local SUPERCONDUCTORS = {
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UHV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UEV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UIV.id,
    resources.FLUIDS.MOLTEN_SUPERCONDUCTOR_UMV.id
}

--- 单份需求条目（need 与 stockRequirements 共用）
local SUPERCOOLANT = {
    fluid = resources.FLUIDS.SUPERCOOLANT.id,
    amount = 10000,
    label = resources.FLUIDS.SUPERCOOLANT.label
}
local GAS_HE = {
    fluid = resources.FLUIDS.HELIUM.id,
    amount = 10000,
    label = resources.FLUIDS.HELIUM.label
}
local GAS_NE = {
    fluid = resources.FLUIDS.NEON.id,
    amount = 7500,
    label = resources.FLUIDS.NEON.label
}
local GAS_KR = {
    fluid = resources.FLUIDS.KRYPTON.id,
    amount = 5000,
    label = resources.FLUIDS.KRYPTON.label
}
local GAS_XE = {
    fluid = resources.FLUIDS.XENON.id,
    amount = 2500,
    label = resources.FLUIDS.XENON.label
}
local SUPERCONDUCTOR = { any = SUPERCONDUCTORS, amount = 1440, label = "熔融超导粗胚" }
local NEUTRONIUM = {
    fluid = resources.FLUIDS.MOLTEN_NEUTRONIUM.id,
    amount = 4608,
    label = resources.FLUIDS.MOLTEN_NEUTRONIUM.label
}

--- 原料巡检用：全部流体各"一份"（与当前控制信号无关）
local STOCK = { SUPERCOOLANT, GAS_HE, SUPERCONDUCTOR, GAS_NE, NEUTRONIUM, GAS_KR, GAS_XE }

t7.priority = 40 -- 最后调度

--- 侧位自动配置用：7 项全集（只看有没有，不看量）
local FLUIDS = {
    resources.FLUIDS.SUPERCOOLANT,
    resources.FLUIDS.HELIUM,
    { label = "熔融超导粗胚（UV-UMV 任意）", any = SUPERCONDUCTORS },
    resources.FLUIDS.NEON,
    resources.FLUIDS.MOLTEN_NEUTRONIUM,
    resources.FLUIDS.KRYPTON,
    resources.FLUIDS.XENON
}


--- 原料巡检用：全部流体各一份（任何控制信号下都应具备）
-- @return table { {fluid|any, amount, label}, ... }
function t7.stockRequirements() return STOCK end

--- 该级自动化的最低转运速率（mB/s；T7 专属，其它级可各自定义）
-- 200000 mB/s → 单笔上限 floor(rate*0.05)=10000，T7 每种流体恰好一笔且永不 pause。
-- @return number
function t7.minTransferRate() return 200000 end
function t7.requiredFluids() return FLUIDS end

--- 控制信号数值 → 本轮需求清单
-- @param signal number 二进制控制值
-- @return table|nil 需求数组（空表 = 无需求；nil = 读不到控制信号）
-- @return string|nil 原因
-- @return number|nil 原始控制数（日志用）
function t7.demand(signal)
    local n = tonumber(signal)
    if n == nil then return nil, "读不到控制信号", nil end
    if n >= 8 then return {}, nil, n end               -- 位4：忽略全部位

    if n == 0 then                                     -- 无任何位：超级冷却液
        return { SUPERCOOLANT }, nil, n
    end

    local out = {}
    if n % 2 == 1 then                                 -- 位1：稀有气体
        local gas = math.floor(n / 2) % 4              -- 位2-3：0氦 1氖 2氪 3氙
        if gas == 0 then out[#out + 1] = GAS_HE
        elseif gas == 1 then out[#out + 1] = GAS_NE
        elseif gas == 2 then out[#out + 1] = GAS_KR
        else out[#out + 1] = GAS_XE end
    end
    if math.floor(n / 2) % 2 == 1 then                 -- 位2：超导粗胚
        out[#out + 1] = SUPERCONDUCTOR
    end
    if math.floor(n / 4) % 2 == 1 then                 -- 位3：熔融中子
        out[#out + 1] = NEUTRONIUM
    end
    return out, nil, n
end

function t7.need() return {}, nil, nil end

function t7.operation(ctx)
    local signal, err = ctx.sensorInfo("controlSignal")
    if signal == nil then return false, tostring(err or "读不到控制信号") end
    local demand, why = t7.demand(signal)
    if not demand then return false, tostring(why) end
    if #demand == 0 then return true end
    for _, need in ipairs(demand) do
        local ok, itemWhy
        if need.fluid then
            ok, itemWhy = ctx.transferFluid(need.fluid, need.amount, need.label)
        else
            ok, itemWhy = ctx.transferAny(need.any, need.amount, need.label)
        end
        if not ok then return false, itemWhy end
    end
    return true
end
return t7
