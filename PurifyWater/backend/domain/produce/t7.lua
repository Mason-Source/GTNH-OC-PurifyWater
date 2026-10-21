--------------------------------------------------------------------------------
-- backend/domain/produce/t7.lua
--------------------------------------------------------------------------------
-- 【职责】T7（脱气）制作自动化方法：控制信号 → 本轮需求（位规则）
-- 【不做什么】不碰组件、不写状态、不做转运
-- 【依赖】无
-- 【被谁用】main.lua（注册到 backend/domain/produce）
--
-- 【控制信号位规则】（行尾二进制串；低位权重 1）
--   位1(1)  稀有气体：种类 = 位2-3（0 氦 10000 / 1 氖 7500 / 2 氪 5000 / 3 氙 2500）
--   位2(2)  熔融超导粗胚 1440L（具体款按输入侧实有解析）
--   位3(4)  熔融中子 4608L
--   位4(8)  忽略全部位，不投
--   0       超级冷却液 10000L（实测：无任何位返回 0，不是空）

--------------------------------------------------------------------------------

local t7 = {}

-- 熔融超导粗胚：UV-UMV 任意一种都算满足（名字与旧脚本的 5 个变量一致）
local SUPERCONDUCTORS = {
    "molten.longasssuperconductornameforuvwire",
    "molten.longasssuperconductornameforuhvwire",
    "molten.superconductoruevbase",
    "molten.superconductoruivbase",
    "molten.superconductorumvbase"
}

--- 单份需求条目（need 与 stockRequirements 共用，字面量只写一次）
local SUPERCOOLANT   = { fluid = "supercoolant", amount = 10000, label = "超级冷却液" }
local GAS_HE         = { fluid = "helium",  amount = 10000, label = "氦" }
local GAS_NE         = { fluid = "neon",    amount = 7500,  label = "氖" }
local GAS_KR         = { fluid = "krypton", amount = 5000,  label = "氪" }
local GAS_XE         = { fluid = "xenon",   amount = 2500,  label = "氙" }
local SUPERCONDUCTOR = { any = SUPERCONDUCTORS, amount = 1440, label = "熔融超导粗胚" }
local NEUTRONIUM     = { fluid = "molten.neutronium", amount = 4608, label = "熔融中子" }

--- 原料巡检用：全部流体各"一份"（与当前控制信号无关）
local STOCK = { SUPERCOOLANT, GAS_HE, SUPERCONDUCTOR, GAS_NE, NEUTRONIUM, GAS_KR, GAS_XE }

t7.priority = 40 -- 最后调度

--- 侧位自动配置用：7 项全集（只看有没有，不看量）
local FLUIDS = {
    SUPERCOOLANT.fluid,
    GAS_HE.fluid,
    { label = "熔融超导粗胚（UV-UMV 任意）", any = SUPERCONDUCTORS },
    GAS_NE.fluid,
    NEUTRONIUM.fluid,
    GAS_KR.fluid,
    GAS_XE.fluid
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
            ok, itemWhy = ctx.transferFluid(need.fluid, need.amount)
        else
            ok, itemWhy = ctx.transferAny(need.any, need.amount)
        end
        if not ok then return false, itemWhy end
    end
    return true
end
return t7
