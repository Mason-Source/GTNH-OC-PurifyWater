--------------------------------------------------------------------------------
-- backend/domain/produce/check.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化纯就绪性检查：绑定齐、转运器在线、最低速率
-- 【不做什么】不读 state、不碰组件、不写盘
--------------------------------------------------------------------------------

local check = {}

local function short(address)
    local s = tostring(address or "")
    if s == "" then return "-" end
    return s:sub(1, 8)
end

--- 就绪性检查
-- @param level number
-- @param units table 每台机器一条 { machine=, transposer=, online=, rate= }
-- @param env table { machines = { [地址] = true }, minRate = number|nil }
-- @return boolean ok
-- @return string|nil reason
function check.run(level, units, env)
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

return check
