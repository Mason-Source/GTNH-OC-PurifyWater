--------------------------------------------------------------------------------
-- backend/hardware/transposer.lua
--------------------------------------------------------------------------------
-- 【职责】转运器（transposer）组件操作：数容器 / 列容器内容（唯一碰转运器处）
-- 【不做什么】不判业务（输出侧 / 输入侧怎么选由 app/produce 决定）
-- 【依赖】backend/hardware/device（唯一 invoke 出口）
-- 【被谁用】backend/app/produce（侧位自动配置 / 原料巡检 / 周期投料）
--
-- tank 索引基准（0 基 / 1 基）与返回字段（name/amount 还是 fluid.*）以实机为准：
-- containers() 给的索引与后续转运原样回传；转运（transferFluid）在转运执行落地时再加。
--------------------------------------------------------------------------------

local device     = require("backend.hardware.device")

local transposer = {}

--- 该面暴露出的容器数（没有容器返回 nil + 原因）
-- 只有 >0 才算"这个面有容器"：0 表示"没有可转运的容器"（空面 / 纯物品容器），
-- 不能当"一个空容器"——否则没接容器的面也会被算成输出侧候选。
-- @param address string 转运器地址
-- @param side number 面
-- @return number|nil
-- @return string|nil
function transposer.tanks(address, side)
    local count, err, second = device.invoke(address, "getTankCount", side)
    if err then return nil, err end
    if type(count) == "number" and count > 0 then return count, nil end
    return nil, tostring(second or "无容器")
end

--- 该面容器内每个罐的内容（空罐也列出来：fluid = nil）
-- @param address string 转运器地址
-- @param side number 面
-- @return table|nil { {tank=索引, fluid=流体注册名|nil, amount=mB}, ... }（没有容器 -> nil）
-- @return string|nil 失败原因
function transposer.containers(address, side)
    local count, err = transposer.tanks(address, side)
    if not count then return nil, err end

    -- 实机形状（探针已确认）：{ amount=, capacity=, id=, label=, name= }；空罐没有 name。
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

--- 该面物品库存大小（没有物品库存返回 nil + 原因）
-- @param address string 转运器地址
-- @param side number 面
-- @return number|nil
-- @return string|nil
function transposer.inventorySize(address, side)
    local size, err, second = device.invoke(address, "getInventorySize", side)
    if err then return nil, err end
    if type(size) == "number" and size > 0 then return size, nil end
    return nil, tostring(second or "无物品库存")
end

--- 该面非空物品槽（含 name / damage / label / size / maxSize）
-- @param address string 转运器地址
-- @param side number 面
-- @param knownSize number|nil 调用方已经读过库存大小时传入，避免重复 getInventorySize
-- @return table|nil { {slot=, name=, damage=, label=, size=, maxSize=}, ... }
-- @return string|nil
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

--- 转运物品（sourceSlot 1 基；返回实际移动数或失败原因）
-- @param address string 转运器地址
-- @param from number 源面
-- @param to number 目标面
-- @param count number 数量
-- @param sourceSlot number 源槽（1 基）
-- @return boolean ok
-- @return number|string 实际移动数 | 失败原因
function transposer.transferItems(address, from, to, count, sourceSlot)
    local moved, _, second = device.invoke(address, "transferItem", from, to, count, sourceSlot)
    if type(moved) == "number" then return true, moved end
    return false, tostring(second or "物品转运失败")
end

--- 转运器速率（mB/s；由方块 NBT / 配置决定，升级会变）
-- @param address string 转运器地址
-- @return number|nil
-- @return string|nil
function transposer.rate(address)
    local value, err = device.invoke(address, "getFluidTransferRate")
    if type(value) == "number" then return value, nil end
    return nil, err or "读不到转运速率"
end

--- 把某个面的流体抽到另一个面（sourceTank 用 1 基，与 getFluidInTank 一致）
-- 实机（GTNH）的 transferFluid 第 4 参是 **0 基**：这里统一减 1，调用方永远用读罐的索引。
-- （项目内 OC API 文档写的是 1 基；实机报错 `ti[sourceTank].fluid is null` 证明是 0 基。）
-- @param address string 转运器地址
-- @param from number 源面
-- @param to number 目标面
-- @param amount number 抽取量（mB）
-- @param sourceTank number 源罐索引（1 基）
-- @return boolean ok
-- @return number|string 实际移动量 | 失败原因
function transposer.transfer(address, from, to, amount, sourceTank)
    local moved, _, second = device.invoke(address, "transferFluid", from, to, amount,
        math.max(0, (tonumber(sourceTank) or 1) - 1))
    if moved == true then
        return true, tonumber(second) or amount
    end
    return false, tostring(second or "转运失败")
end

return transposer