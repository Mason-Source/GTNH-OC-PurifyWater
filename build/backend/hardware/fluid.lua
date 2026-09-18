local constants = require("shared.constants")
local utils     = require("shared.utils")
local device    = require("backend.hardware.device")
local fluid     = {}
local function amountOf(item)
    if type(item) ~= "table" then return 0 end
    return math.max(0, tonumber(item.size or item.amount or 0) or 0)
end
function fluid.readAll()
    local address = device.me()
    if not address then return {}, false, "未连接 ME 网络接口" end
    local list, listErr = device.invoke(address, "getFluidsInNetwork")
    if type(list) ~= "table" then
        return {}, false, "ME 接口读取失败：" .. tostring(listErr or "返回值不是列表")
    end
    local byName = {}
    for _, item in ipairs(list) do
        if type(item) == "table" and item.name then
            byName[utils.normalizeFluidName(item.name)] = amountOf(item)
        end
    end
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = byName[utils.normalizeFluidName(constants.FLUID_NAMES[level])] or 0
    end
    return out, true, nil
end
return fluid
