-- 制作自动化方法注册表；各等级实现由独立状态机文件提供。
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

function produce.register(level, implementation)
    level = tonumber(level)
    assert(level and level >= 1 and level <= constants.LEVEL_COUNT, "制作自动化等级越界")
    assert(type(implementation) == "table", "制作自动化实现必须是表")
    assert(type(implementation.build) == "function", "制作自动化实现缺 build()")
    assert(type(implementation.states) == "table", "制作自动化实现缺 states")
    implementation.level = level
    impls[level] = implementation
end

function produce.has(level)
    return impls[tonumber(level)] ~= nil
end

function produce.method(level)
    return impls[tonumber(level)]
end

function produce.levels()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        if impls[level] then out[#out + 1] = impls[level] end
    end
    return out
end

function produce.requiredFluids(level)
    local method = produce.method(level)
    return method and method.requiredFluids and method.requiredFluids() or nil
end

function produce.requiredItems(level)
    local method = produce.method(level)
    return method and method.requiredItems and method.requiredItems() or nil
end

function produce.minTransferRate(level)
    local method = produce.method(level)
    return method and method.minTransferRate and method.minTransferRate() or nil
end

return produce