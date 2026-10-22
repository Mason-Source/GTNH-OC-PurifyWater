--------------------------------------------------------------------------------
-- backend/domain/produce/t8.lua
--------------------------------------------------------------------------------
-- 【职责】T8（萃取）制作自动化方法：按最短覆盖路径逐周期投夸克释放催化剂
-- 【不做什么】不碰组件、不写状态；等待与投料都经 operation ctx 异步执行
-- 【依赖】shared/{resources,utils}
-- 【被谁用】main.lua（注册到 backend/domain/produce）、produce_job（执行）
--
-- 【机器机制】每个主周期开始时，机器随机选择两种不同的夸克释放催化剂；
--   输入序列中任意相邻的两种催化剂命中该组合（顺序无关）即判定成功。
--   周期开始会清空本周期催化剂历史，因此每周期必须从覆盖序列开头重新投料。
--
-- 【最短遍历】六种催化剂视为 K6 的 6 个顶点，任意两种组合是一条边，共 15 条。
--   K6 的 6 个顶点度数均为奇数，不存在一次覆盖全部边的欧拉路径；每条开放路径
--   最多消化 2 个奇点，因此至少要 3 条路径、额外重复 2 条边，即 17 条边 / 18 个顶点。
--   下面的 WALK 正是该下界的构造，覆盖全部 15 种无序组合，仅重复 {2,3} 与 {4,6}。
--------------------------------------------------------------------------------

local resources = require("shared.resources")
local utils = require("shared.utils")

local t8 = {}

-- 节点顺序固定；任意六种催化剂的排列都保持覆盖性质。
local CATALYSTS = {
    resources.ITEMS.QUARK_UP_CATALYST,      -- Up
    resources.ITEMS.QUARK_DOWN_CATALYST,    -- Down
    resources.ITEMS.QUARK_STRANGE_CATALYST, -- Strange
    resources.ITEMS.QUARK_CHARM_CATALYST,   -- Charm
    resources.ITEMS.QUARK_BOTTOM_CATALYST,  -- Bottom
    resources.ITEMS.QUARK_TOP_CATALYST      -- Top
}

-- 18 个顶点 = 17 条相邻边；覆盖 K6 全部 15 条边 + 2 条必要重复边。
local WALK = { 1, 2, 3, 4, 5, 6, 2, 4, 6, 1, 3, 5, 1, 4, 6, 3, 2, 5 }

-- 原料巡检用：按最坏情况要求每种催化剂各走完整条 WALK 所需数量。
local STOCK = {}
for node, item in ipairs(CATALYSTS) do
    local used = 0
    for _, step in ipairs(WALK) do
        if step == node then used = used + 1 end
    end
    STOCK[#STOCK + 1] = { item = item, amount = used, label = item.label }
end

-- 投料后等待机器吸收（机器每 20 tick 从输入总线收取一次）。
local SETTLE_SECONDS = 1.25

t8.CATALYSTS = CATALYSTS
t8.WALK      = WALK
t8.priority  = 10 -- 排在 T6 后、T3 前

--- 侧位自动配置用：输入总线需要六种催化剂，目标侧是空的输入总线
function t8.requiredItems() return CATALYSTS end

--- 使用物品侧（界面显示与文档语义；实际判定仍以 requiredItems 为准）
function t8.usesItems() return true end

--- 原料巡检用：按最坏情况要求每种催化剂各 3 个
function t8.stockRequirements() return STOCK end

--- 通用框架接口占位；T8 的逐周期投料在 operation 内完成
function t8.need() return {}, nil, nil end

local function readSuccess(ctx)
    local success, err = ctx.sensorInfo("success")
    if success == nil then return nil, tostring(err or "成功率不可读") end
    return utils.toPercent(success), nil
end

--- 一个主周期内按最短覆盖序列投料；通用 success 字段命中 100% 即停。
-- @param ctx operation context
-- @return boolean ok
-- @return string|nil reason
function t8.operation(ctx)
    local success, err = readSuccess(ctx)
    if success == nil then return false, err end
    if success >= 99.5 then return true end

    for _, node in ipairs(WALK) do
        if not ctx.active() then return false, "机器 active=false" end

        local item = CATALYSTS[node]
        local ok, why = ctx.transferItem(item, 1)
        if not ok then
            return false, string.format("%s 投料失败：%s", item.label, tostring(why))
        end

        ctx.wait(SETTLE_SECONDS)
        success, err = readSuccess(ctx)
        if success == nil then return false, err end
        if success >= 99.5 then return true end
    end

    return false, "18 枚催化剂已投完，但通用 success 字段未达到 100%"
end

return t8
