--------------------------------------------------------------------------------
-- backend/domain/produce/t4.lua
--------------------------------------------------------------------------------
-- 【职责】T4（pH 调节）制作自动化方法：读 pH → 精确补碱/补酸
-- 【不做什么】不碰组件、不写状态、不做转运
-- 【依赖】无
-- 【被谁用】main.lua（注册到 backend/domain/produce）
--
-- 【机器机制】GT5U 的 pH 调节单元每 1 秒把输入总线里的氢氧化钠粉、输入仓里的
--   氢氯酸全部吸走：pH += 粉数量×0.01 − floor(酸量/10)×0.01，保留两位小数；
--   成功率 = |pH − 7| ≤ 0.05。
-- 【需求】pH<6.95 → 补粉 round((7−pH)/0.01) 个（最多 250）；
--         pH>7.05 → 补酸 round((pH−7)/0.01)×10 L（最多 2500 L，必须 10L 倍数）；
--         区间内不投。
-- 【最低速率】50000 mB/s（20 × 2500）；单笔上限 2500 L，最大一次补酸正好一笔。
--------------------------------------------------------------------------------

local t4 = {}

local ACID = "hydrochloricacid_gt5u" -- 氢氯酸（实机注册名）
local ALKALINE = {
    name   = "gregtech:gt.metaitem.01",
    damage = 2685,
    label  = "氢氧化钠粉"
}

local PH_TARGET    = 7
local PH_TOLERANCE = 0.05
local PH_PER_DUST  = 0.01
local PH_PER_10_ACID = 0.01
local MAX_DUST     = 250 -- 单轮最大实际需求
local MAX_ACID     = 2500
local STOCK_DUST   = 64  -- 物品开闸阈值：按大多数物品容器可读的一格堆叠量
local FLUIDS = { ACID }
local ITEMS  = { ALKALINE }

t4.priority = 30 -- 排在 T3 后、T7 前


--- 侧位自动配置用：输入侧需要氢氯酸（流体）
function t4.requiredFluids() return FLUIDS end

--- 侧位自动配置用：输入侧需要氢氧化钠粉（物品）
function t4.requiredItems() return ITEMS end

--- 该级同时用物品和流体（输出侧需要物品+流体存储空间）
function t4.usesItems() return true end

--- 原料巡检用：物品按单格 64、流体按单轮最大消耗检查，不按当前 pH 的临时需求。
--- T4 初始 pH 范围为 4.5-9.5，实际单轮最大需求为 250 个粉 / 2500 L 酸；
--- 但物品开闸按一格 64 检查，实际投料由安全泵分批补足。
local STOCK = {
    { item = ALKALINE, amount = STOCK_DUST, label = "氢氧化钠粉" },
    { fluid = ACID, amount = MAX_ACID, label = "氢氯酸" }
}
function t4.stockRequirements() return STOCK end

--- 该级最低转运速率（mB/s）
function t4.minTransferRate() return 50000 end

--- 氢氯酸单笔必须是 10L 的倍数（机器按 10L 取整，零头会被浪费）
function t4.fluidUnit() return 10 end

--- pH → 本轮需求（补粉/补酸/不投）
-- @param ph number
-- @return table|nil 需求数组（空表 = 已达标；nil = 读不到 pH）
-- @return string|nil 原因
-- @return number|nil 当前 pH（日志用）
function t4.demand(ph)
    ph = tonumber(ph)
    if ph == nil then return nil, "读不到 pH", nil end
    if ph <= 0 then return nil, "pH 尚未初始化", ph end

    local errorValue = PH_TARGET - ph
    if math.abs(errorValue) <= PH_TOLERANCE then
        return {}, nil, ph
    end

    if errorValue > 0 then
        local count = math.min(MAX_DUST, math.floor(errorValue / PH_PER_DUST + 0.5))
        return { { item = ALKALINE, amount = count, label = "氢氧化钠粉" } }, nil, ph
    end

    local doses = math.floor((-errorValue) / PH_PER_10_ACID + 0.5)
    local amount = math.min(MAX_ACID, doses * 10)
    return { { fluid = ACID, amount = amount, label = "氢氯酸" } }, nil, ph
end

function t4.need() return {}, nil, nil end

function t4.operation(ctx)
    local ph, err = ctx.sensorInfo("ph")
    if ph == nil then return false, tostring(err or "读不到 pH") end
    local demand, why = t4.demand(ph)
    if not demand then return false, tostring(why) end
    if #demand == 0 then return true end
    for _, need in ipairs(demand) do
        local ok, itemWhy
        if need.item then
            ok, itemWhy = ctx.transferItem(need.item, need.amount)
        else
            ok, itemWhy = ctx.transferFluid(need.fluid, need.amount)
        end
        if not ok then return false, itemWhy end
    end
    return true
end
return t4
