--------------------------------------------------------------------------------
-- backend/hardware/fluid.lua
--------------------------------------------------------------------------------
-- 【职责】从 ME 网络接口读 1-8 级水的库存（mB）
-- 【不做什么】不判断能不能开（那是 domain/rules）；不写盘（曲线走 store/history）
-- 【依赖】hardware/device、shared/{constants,utils}
-- 【被谁用】backend/jobs（T2）
--
-- 读取失败返回 nil，调用方按 0：无缓存是正常态，只强开源头级。
-- 列表读成功但无该流体 = 数量 0；整份列表失败才算读取失败。
-- 走 device.invoke。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local utils     = require("shared.utils")
local device    = require("backend.hardware.device")

local fluid     = {}

--- 取数量（AE2 字段名 size/amount）
-- @param item table|nil
-- @return number
local function amountOf(item)
    if type(item) ~= "table" then return 0 end
    return math.max(0, tonumber(item.size or item.amount or 0) or 0)
end

--- 读 1-8 级水量
-- @return table { [level] = number }（读取失败时该级为 nil）
-- @return boolean 本次是否读到
-- @return string|nil 失败原因（成功为 nil）
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
        -- 列表权威：无该项 = 0
        out[level] = byName[utils.normalizeFluidName(constants.FLUID_NAMES[level])] or 0
    end
    return out, true, nil
end

return fluid
