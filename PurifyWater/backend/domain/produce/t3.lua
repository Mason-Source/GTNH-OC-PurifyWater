--------------------------------------------------------------------------------
-- backend/domain/produce/t3.lua
--------------------------------------------------------------------------------
-- 【职责】T3（絮凝）制作自动化方法：固定需求 —— 聚氯化铝 900,000 mB / 周期
-- 【不做什么】不碰组件、不写状态、不做转运
-- 【依赖】无
-- 【被谁用】main.lua（注册到 backend/domain/produce）
--
-- 【需求】每周期输入 900,000 mB polyaluminiumchloride（聚氯化铝）。
-- 【最低速率】2,621,440 mB/s（T3 专属；单笔上限 floor(rate*0.05)=131072，
--   900,000 需要 7 笔，每笔一个 game tick，全程不触发 context.pause）。
--------------------------------------------------------------------------------

local t3 = {}

local FLUID  = "polyaluminiumchloride"
local AMOUNT = 900000

local ENTRY = { fluid = FLUID, amount = AMOUNT, label = "聚氯化铝" }
local FLUIDS = { FLUID }
local STOCK  = { ENTRY }

t3.priority = 20 -- 排在 T8 后、T4 前

--- 侧位自动配置用：只有一种流体（只看有没有）
-- @return table
function t3.requiredFluids() return FLUIDS end

--- 原料巡检用：一份 = 900,000 mB
-- @return table
function t3.stockRequirements() return STOCK end

--- 该级自动化的最低转运速率（mB/s；T3 专属）
-- @return number
function t3.minTransferRate() return 2621440 end

--- 本轮需求：固定投 900,000 mB 聚氯化铝（与传感器无关）
-- @param lines table 传感器文本行（本方法不使用）
-- @return table 需求数组
function t3.need(lines) return { ENTRY } end

function t3.operation(ctx)
    local ok, why = ctx.transferFluid(FLUID, AMOUNT)
    if not ok then return false, why end
    return true
end
return t3
