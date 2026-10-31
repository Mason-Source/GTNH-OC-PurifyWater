-- ME 水位读取。
local device = require("hardware.device")
local constants = require("shared.constants")
local resources = require("shared.resources")

local fluid = {}

local function interfaceAddress(devices)
    for _, item in ipairs(devices or {}) do
        if item.kind == "fluid_interface" or item.kind == "me_interface" then
            return item.address
        end
    end
end

local function amountOf(item)
    if type(item) ~= "table" then return 0 end
    return tonumber(item.size or item.amount or 0) or 0
end

function fluid.readAll(devices)
    local address = interfaceAddress(devices)
    if not address then return nil, "ME interface not found" end

    local list, err = device.invoke(address, "getFluidsInNetwork")
    if type(list) ~= "table" then return nil, err or "invalid fluid list" end

    local byName = {}
    for _, item in ipairs(list) do
        if type(item) == "table" and item.name then
            byName[tostring(item.name):lower():gsub("^gregtech:", "")] = amountOf(item)
        end
    end

    local levels = {}
    for level = 1, constants.LEVEL_COUNT do
        local id = resources.purifiedWaterId(level)
        local name = tostring(id or ""):lower():gsub("^gregtech:", "")
        levels[level] = byName[name] or 0
    end
    return levels
end

return fluid
