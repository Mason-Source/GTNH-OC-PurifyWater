--------------------------------------------------------------------------------
-- backend/hardware/fluid.lua
--------------------------------------------------------------------------------
-- 【职责】从 ME 网络接口读 1-8 级水的库存（mB）
-- 【不做什么】不判断能不能开（那是 domain/rules）；不写盘（曲线走 store/history）
-- 【依赖】hardware/device、shared/{constants,utils}
-- 【被谁用】backend/jobs（T2）
--
-- 【读不到就返回 nil】调用方据此发 `fluid_unavailable` —— 宁可停，也不拿旧水量继续开机器。
-- 【语义】网络列表读成功时，**列表里没有这种流体 = 网络里就是 0**，不是"读不到"
--   （只有整份列表没拿到才算读不到）；否则 rules 会把"该级没水"误判成"水位读不到"。
-- 【读法】一次拿回全网流体（`getFluidsInNetwork`，实机验证可用）。
-- 【调用约定】走 `device.invoke`（见 device.lua）。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local utils     = require("shared.utils")
local device    = require("backend.hardware.device")

local fluid     = {}

--- 从返回项里取数量（AE2 各版本字段名可能是 size 或 amount）
-- @param item table|nil
-- @return number
local function amountOf(item)
    if type(item) ~= "table" then return 0 end
    return math.max(0, tonumber(item.size or item.amount or 0) or 0)
end

--- 读 1-8 级水量
-- @return table { [level] = number }（读不到时该级为 nil）
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
        -- 列表是权威：列表里没有 = 网络里就是 0（不是读不到）
        out[level] = byName[utils.normalizeFluidName(constants.FLUID_NAMES[level])] or 0
    end
    return out, true, nil
end

return fluid
