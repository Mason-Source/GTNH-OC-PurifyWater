local device     = require("backend.hardware.device")
local transposer = {}
function transposer.tanks(address, side)
    local count, err, second = device.invoke(address, "getTankCount", side)
    if err then return nil, err end
    if type(count) == "number" and count > 0 then return count, nil end
    return nil, tostring(second or "无容器")
end
function transposer.containers(address, side)
    local count, err = transposer.tanks(address, side)
    if not count then return nil, err end
    local out = {}
    for tank = 1, count do
        local info = device.invoke(address, "getFluidInTank", side, tank)
        out[#out + 1] = {
            tank   = tank,
            fluid  = (type(info) == "table") and info.name or nil,
            amount = (type(info) == "table") and (tonumber(info.amount) or 0) or 0
        }
    end
    return out, nil
end
function transposer.inventorySize(address, side)
    local size, err, second = device.invoke(address, "getInventorySize", side)
    if err then return nil, err end
    if type(size) == "number" and size > 0 then return size, nil end
    return nil, tostring(second or "无物品库存")
end
function transposer.items(address, side, knownSize)
    local size, err
    if type(knownSize) == "number" and knownSize > 0 then
        size = knownSize
    else
        size, err = transposer.inventorySize(address, side)
    end
    if not size then return nil, err end
    local out = {}
    for slot = 1, size do
        local stack = device.invoke(address, "getStackInSlot", side, slot)
        if type(stack) == "table" and stack.name then
            out[#out + 1] = {
                slot    = slot,
                name    = stack.name,
                damage  = tonumber(stack.damage) or 0,
                label   = stack.label,
                size    = tonumber(stack.size) or 0,
                maxSize = tonumber(stack.maxSize) or 64
            }
        end
    end
    return out, nil
end
function transposer.transferItems(address, from, to, count, sourceSlot)
    local moved, _, second = device.invoke(address, "transferItem", from, to, count, sourceSlot)
    if type(moved) == "number" then return true, moved end
    return false, tostring(second or "物品转运失败")
end
function transposer.rate(address)
    local value, err = device.invoke(address, "getFluidTransferRate")
    if type(value) == "number" then return value, nil end
    return nil, err or "读不到转运速率"
end
function transposer.transfer(address, from, to, amount, sourceTank)
    local moved, _, second = device.invoke(address, "transferFluid", from, to, amount,
        math.max(0, (tonumber(sourceTank) or 1) - 1))
    if moved == true then
        return true, tonumber(second) or amount
    end
    return false, tostring(second or "转运失败")
end
return transposer
