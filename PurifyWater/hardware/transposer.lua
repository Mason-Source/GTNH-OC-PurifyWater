--------------------------------------------------------------------------------
-- PurifyWater/hardware/transposer.lua
--
-- 定位：转运器原语封装。
-- 功能：读取整面流体罐与物品槽，查询转运速率，并执行单次流体或物品转运。
-- 边界：不持有业务状态，不判断生产配方，不重试或选择资源。
--------------------------------------------------------------------------------

local device = require("hardware.device")

local transposer = {}

local function tankEntry(tank, info)
    if type(info) == "string" then
        return { tank = tank, fluid = info, amount = 0 }
    end
    if type(info) ~= "table" then
        return { tank = tank, fluid = nil, amount = 0 }
    end
    local fluid = info.fluid
    local name = info.name or (type(fluid) == "table" and fluid.name) or fluid
    local amount = info.amount or (type(fluid) == "table" and fluid.amount) or 0
    return {
        tank = tank,
        fluid = (type(name) == "string" and name ~= "") and name or nil,
        amount = tonumber(amount) or 0,
    }
end

local function numericLen(value)
    local length = 0
    for key in pairs(value or {}) do
        if type(key) == "number" and key > length then length = key end
    end
    return length
end

local function allTankEntries(all)
    if type(all) ~= "table" or next(all) == nil then return nil end
    if all.name ~= nil or all.amount ~= nil or all.fluid ~= nil then
        return { tankEntry(1, all) }
    end
    local count = numericLen(all)
    if count <= 0 then return nil end
    local out = {}
    for tank = 1, count do out[#out + 1] = tankEntry(tank, all[tank]) end
    return out
end

--- 读取某面全部流体罐；没有流体容器时返回 nil 和原因。
---@param address string 转运器地址。
---@param side number 面编号。
---@return table|nil containers 罐位列表。
---@return string|nil reason 失败原因。
function transposer.containers(address, side)
    local all, err = device.invoke(address, "getFluidInTank", side)
    local out = allTankEntries(all)
    if out then return out, nil end
    return nil, tostring(err or "无流体容器")
end

local function allStacksEntries(value)
    if value == nil then return nil end
    local ok, all = pcall(function() return value:getAll() end)
    if not ok or type(all) ~= "table" then return nil end
    local out = {}
    for index, stack in pairs(all) do
        local slot = tonumber(index)
        if slot and type(stack) == "table" and stack.name then
            out[#out + 1] = {
                slot = slot + 1,
                name = stack.name,
                damage = tonumber(stack.damage) or 0,
                label = stack.label,
                size = tonumber(stack.size) or 0,
                maxSize = tonumber(stack.maxSize) or 64,
            }
        end
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end

--- 读取某面全部非空物品槽。
--- 空库存返回空表；不可读取时返回 nil 和原因。
---@param address string 转运器地址。
---@param side number 面编号。
---@return table|nil stacks 槽位列表。
---@return string|nil reason 失败原因。
function transposer.items(address, side)
    local value, err = device.invoke(address, "getAllStacks", side)
    local out = allStacksEntries(value)
    if out then return out, nil end
    return nil, tostring(err or "无物品库存")
end

--- 读取转运器流体速率（L/s）。
--- 只在绑定时或显式刷新时调用。
---@param address string 转运器地址。
---@return number|nil rate 每秒可转运量。
---@return string|nil reason 失败原因。
function transposer.rate(address)
    local value, err = device.invoke(address, "getFluidTransferRate")
    if type(value) == "number" then return value, nil end
    return nil, tostring(err or "读不到转运速率")
end

--- 执行一次流体转运。
--- `sourceTank` 对外使用 1 基编号，调用实机 API 时转换为 0 基。
---@param address string 转运器地址。
---@param from number 来源面。
---@param to number 目标面。
---@param amount number 请求转运量。
---@param sourceTank number 来源罐编号。
---@return boolean ok 是否成功。
---@return number|string movedOrReason 实际转运量或失败原因。
function transposer.transferFluid(address, from, to, amount, sourceTank)
    local moved, _, second = device.invoke(address, "transferFluid", from, to, amount,
        math.max(0, (tonumber(sourceTank) or 1) - 1))
    if moved == true then return true, tonumber(second) or amount end
    return false, tostring(second or "转运失败")
end

--- 执行一次物品转运。
---@param address string 转运器地址。
---@param from number 来源面。
---@param to number 目标面。
---@param count number 请求转运数量。
---@param sourceSlot number 来源槽位。
---@return boolean ok 是否成功。
---@return number|string movedOrReason 实际转运数量或失败原因。
function transposer.transferItem(address, from, to, count, sourceSlot)
    local moved, _, second = device.invoke(address, "transferItem", from, to, count, sourceSlot)
    if type(moved) == "number" then return true, moved end
    return false, tostring(second or "物品转运失败")
end

return transposer
