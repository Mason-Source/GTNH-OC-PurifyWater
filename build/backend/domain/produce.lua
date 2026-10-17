local constants = require("shared.constants")
local state     = require("shared.state")
local produce   = {}
local impls     = {}
local REQUIRED  = { "need" }
function produce.register(level, impl)
    level = tonumber(level)
    assert(level and level >= 1 and level <= constants.LEVEL_COUNT,
        "制作自动化方法等级越界：" .. tostring(level))
    assert(type(impl) == "table",
        string.format("%s 的制作自动化方法实现必须是表", constants.levelLabel(level)))
    for _, name in ipairs(REQUIRED) do
        assert(type(impl[name]) == "function",
            string.format("%s 的制作自动化方法缺接口 %s()", constants.levelLabel(level), name))
    end
    impls[level] = impl
end
function produce.has(level)
    return impls[level] ~= nil
end
function produce.method(level)
    return impls[level]
end
local function short(address)
    local s = tostring(address or "")
    if s == "" then return "-" end
    return s:sub(1, 8)
end
function produce.check(level, units, env)
    if type(level) ~= "number" then return false, "等级无效" end
    if #units == 0 then return false, "该级没有机器" end
    local unbound = 0
    for _, unit in ipairs(units) do
        if not (env.machines or {})[unit.machine] then
            return false, "机器不在该级注册表：" .. short(unit.machine)
        end
        if not unit.transposer then
            unbound = unbound + 1
        elseif not unit.online then
            return false, "转运器不在网：" .. short(unit.transposer)
        elseif env.minRate then
            local rate = unit.rate
            if type(rate) ~= "number" then
                return false, "读不到转运速率：" .. short(unit.machine)
            end
            if rate < env.minRate then
                return false, string.format("转运器速度不足：%d < %d mB/s（机器 %s）",
                    rate, env.minRate, short(unit.machine))
            end
        end
    end
    if unbound > 0 then
        return false, string.format("还有 %d 台机器未绑定", unbound)
    end
    return true, nil
end
function produce.blocked(level)
    local entry = state.read.produceLevel(level)
    if entry.enabled ~= true then return false end
    if entry.valid ~= true then return true end
    for _, sub in pairs(state.read.produce().subs) do
        if sub.level == level and sub.forceOff == true then return true end
    end
    return false
end
return produce
