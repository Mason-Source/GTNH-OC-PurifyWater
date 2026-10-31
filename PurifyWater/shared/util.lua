-- 纯工具；不做 IO 或组件调用。
local util = {}

local SHORT_UNITS = {
    { "P", 1e15 },
    { "T", 1e12 },
    { "G", 1e9 },
    { "M", 1e6 },
    { "K", 1e3 },
}

local GAME_TICKS_PER_HOUR = 1000
local REAL_TICKS_PER_SECOND = 20

function util.clamp(value, minimum, maximum)
    return math.min(maximum, math.max(minimum, value))
end

--- 千分位：1234567 -> "1,234,567"
-- @param value number|nil
-- @return string
function util.formatNumber(value)
    if type(value) ~= "number" then return tostring(value) end
    local text = tostring(math.floor(value))
    text = text:gsub("%.0$", "")
    local sign = text:sub(1, 1) == "-" and "-" or ""
    if sign == "-" then text = text:sub(2) end
    local groups = {}
    while #text > 3 do
        table.insert(groups, 1, text:sub(-3))
        text = text:sub(1, #text - 3)
    end
    table.insert(groups, 1, text)
    return sign .. table.concat(groups, ",")
end

--- V1 同款短单位：1234567 -> "1.23M"（K / M / G / T / P）
-- @param value number|nil
-- @return string
function util.formatShortNumber(value)
    if type(value) ~= "number" then return tostring(value) end
    for _, unit in ipairs(SHORT_UNITS) do
        if math.abs(value) >= unit[2] then
            return string.format("%.2f%s", value / unit[2], unit[1])
        end
    end
    return tostring(math.floor(value))
end

--- OC 的 uptime 秒 -> Minecraft 游戏时。
-- computer.uptime() 已按 20 tick/秒折算为真实秒；Minecraft 1 游戏时 = 1000 tick。
-- @param realSeconds number|nil
-- @return number
function util.realSecondsToGameHours(realSeconds)
    return (tonumber(realSeconds) or 0) * REAL_TICKS_PER_SECOND / GAME_TICKS_PER_HOUR
end

--- Minecraft 流体内部值转为统一显示单位 L。
function util.formatVolume(value)
    return util.formatShortNumber(tonumber(value) or 0) .. "L"
end

function util.shortAddress(address)
    return tostring(address or ""):sub(1, 8)
end

return util
