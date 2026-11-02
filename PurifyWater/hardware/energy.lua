--------------------------------------------------------------------------------
-- PurifyWater/hardware/energy.lua
--
-- 定位：能源仓名称分类与 EU/t 推算。
-- 功能：识别标准、多方块、激光和无线能源仓，并根据名称与缓存值计算输入功率。
-- 边界：只做名称解析和数值换算，不读取组件。
--------------------------------------------------------------------------------

local constants = require("shared.constants")

local energy = {}

local function tierVoltage(name)
    local key = tostring(name or ""):lower()
    for _, tier in ipairs(constants.VOLTAGE_TIERS) do
        if tier.name:lower() == key then return tier.eu end
    end
    return nil
end

local function numericVoltage(tier)
    return 8 * (4 ^ tier)
end

local function laserBufferK(head)
    if head:find("wirelesstunnel", 1, true) then return 4000 end
    if head:find("tunnel", 1, true) then return 24 end
    return nil
end

--- 根据能源仓注册名识别仓型、电压、电流和激光缓存倍率。
function energy.classify(name)
    name = tostring(name or "")
    local head = name:match("^hatch%.([^.]+)") or name

    local gtnlTier, gtnlAmps = name:match("wirelessenergyhatch(%a+)(%d+)a$")
    if gtnlTier then
        local voltage = tierVoltage(gtnlTier)
        local amps = tonumber(gtnlAmps)
        if voltage and amps then
            return {
                kind = "gtnl",
                voltage = voltage,
                amps = amps,
                bufferK = 4000,
            }
        end
        return { kind = "unknown" }
    end

    local tier = tonumber(name:match("tier%.(%d+)"))
    if not tier then return { kind = "unknown" } end

    local tunnel = tonumber(head:match("tunnel(%d+)"))
    if tunnel then
        return {
            kind = "laser",
            voltage = numericVoltage(tier),
            amps = 64 * (4 ^ tunnel),
            bufferK = laserBufferK(head),
        }
    end

    local multi = tonumber(head:match("multi(%d+)"))
    return {
        kind = "standard",
        voltage = numericVoltage(tier),
        amps = multi or 1,
    }
end

--- 计算能源仓可提供的 EU/t 功率及识别出的仓型。
function energy.powerOf(item, euMax)
    local info = energy.classify(item and item.name)
    if info.kind == "unknown" then return 0, "unrecognized energy hatch" end

    if info.bufferK and type(euMax) == "number" and euMax > 0 then
        return math.floor(euMax / info.bufferK + 0.5), info.kind
    end

    return math.floor(info.voltage * info.amps + 0.5), info.kind
end

return energy
