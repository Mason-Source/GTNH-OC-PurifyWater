--------------------------------------------------------------------------------
-- PurifyWater/business/produce.lua
--
-- 定位：制作自动化实现的注册表。
-- 功能：登记 T3-T8 状态机实现，并统一暴露等级支持、原料需求和最低转运速率查询。
-- 边界：不执行任务、不访问组件；实现细节由各等级文件负责。
--------------------------------------------------------------------------------

local constants = require("shared.constants")

local produce = {}
local impls = {}

local BUILTINS = {
    require("business.produce.t3"),
    require("business.produce.t4"),
    require("business.produce.t5"),
    require("business.produce.t6"),
    require("business.produce.t7"),
    require("business.produce.t8"),
}

for _, implementation in ipairs(BUILTINS) do
    impls[implementation.level] = implementation
end

--- 校验并登记一个制作自动化实现。
function produce.register(level, implementation)
    level = tonumber(level)
    assert(level and level >= 1 and level <= constants.LEVEL_COUNT, "制作自动化等级越界")
    assert(type(implementation) == "table", "制作自动化实现必须是表")
    assert(type(implementation.build) == "function", "制作自动化实现缺 build()")
    assert(type(implementation.states) == "table", "制作自动化实现缺 states")
    implementation.level = level
    impls[level] = implementation
end

--- 判断指定等级是否已有制作自动化实现。
function produce.has(level)
    return impls[tonumber(level)] ~= nil
end

--- 返回指定等级的制作自动化实现；未实现时返回 nil。
function produce.method(level)
    return impls[tonumber(level)]
end

--- 按等级顺序返回所有已注册的制作自动化实现。
function produce.levels()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        if impls[level] then out[#out + 1] = impls[level] end
    end
    return out
end

--- 返回指定等级声明的流体需求。
function produce.requiredFluids(level)
    local method = produce.method(level)
    return method and method.requiredFluids and method.requiredFluids() or nil
end

--- 返回指定等级声明的物品需求。
function produce.requiredItems(level)
    local method = produce.method(level)
    return method and method.requiredItems and method.requiredItems() or nil
end

--- 返回指定等级声明的最低转运速率。
function produce.minTransferRate(level)
    local method = produce.method(level)
    return method and method.minTransferRate and method.minTransferRate() or nil
end

return produce