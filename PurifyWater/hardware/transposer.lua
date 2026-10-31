-- 转运器原语：整面读取、速率、单次转运；不持有业务状态。
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

-- 该面全部流体罐；没有流体容器返回 nil + 原因。
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

-- 该面非空物品槽；空库存返回 {}，无物品库存返回 nil + 原因。
function transposer.items(address, side)
    local value, err = device.invoke(address, "getAllStacks", side)
    local out = allStacksEntries(value)
    if out then return out, nil end
    return nil, tostring(err or "无物品库存")
end

-- 转运器流体速率（L/s）。只在绑定时或显式刷新时读取。
function transposer.rate(address)
    local value, err = device.invoke(address, "getFluidTransferRate")
    if type(value) == "number" then return value, nil end
    return nil, tostring(err or "读不到转运速率")
end

-- 流体转运；sourceTank 对外 1 基，实机调用传 0 基。
function transposer.transferFluid(address, from, to, amount, sourceTank)
    local moved, _, second = device.invoke(address, "transferFluid", from, to, amount,
        math.max(0, (tonumber(sourceTank) or 1) - 1))
    if moved == true then return true, tonumber(second) or amount end
    return false, tostring(second or "转运失败")
end

-- 物品转运；sourceSlot 对外 1 基。
function transposer.transferItem(address, from, to, count, sourceSlot)
    local moved, _, second = device.invoke(address, "transferItem", from, to, count, sourceSlot)
    if type(moved) == "number" then return true, moved end
    return false, tostring(second or "物品转运失败")
end

return transposer
