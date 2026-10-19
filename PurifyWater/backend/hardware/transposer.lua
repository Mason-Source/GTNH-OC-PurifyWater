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
-- 物品整面读取优先 getAllStacks(side)：该 GTNH OpenComputers 分支在服务端一次遍历槽位，
-- 返回 ItemStackArrayValue；再通过 :getAll() 一次取回整表。旧版本不支持时回退逐槽。
--------------------------------------------------------------------------------

local device     = require("backend.hardware.device")

local transposer = {}

-- 实机是否支持 getFluidInTank(side) 整面返回；第一次成功后不再为无罐面额外查 getTankCount。
local allTankReadable = nil
local allStacksReadable = nil

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
--
-- 整面读取优先：getFluidInTank(side) 省略 tank 会一次返回该面全部罐。
-- 每次 component.invoke 约 50ms，所以整面读取把 N 个罐的成本从 1+N 次调用降到 1 次；
-- 若某版本不支持整面返回，则退回原来的逐罐读取，语义不变。
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
        tank   = tank,
        fluid  = (type(name) == "string" and name ~= "") and name or nil,
        amount = tonumber(amount) or 0
    }
end

local function numericLen(t)
    local n = 0
    for key in pairs(t or {}) do
        if type(key) == "number" and key > n then n = key end
    end
    return n
end

local function allTankEntries(all)
    if type(all) ~= "table" or next(all) == nil then return nil end
    -- 有些版本可能把单个罐直接返回成 { name=..., amount=... }。
    if all.name ~= nil or all.amount ~= nil or all.fluid ~= nil then
        return { tankEntry(1, all) }
    end
    local count = numericLen(all)
    if count <= 0 then return nil end
    local out = {}
    for tank = 1, count do out[#out + 1] = tankEntry(tank, all[tank]) end
    return out
end

function transposer.containers(address, side)
    -- 优先整面读取：成功时不再先查 getTankCount，单个面从 2 次调用降到 1 次。
    local all, invokeErr = device.invoke(address, "getFluidInTank", side)
    local fast = allTankEntries(all)
    if fast then
        allTankReadable = true
        return fast, nil
    end

    -- 已知支持整面读取时，nil 只可能是这个面没有罐，直接返回，避免再打一次 getTankCount。
    if allTankReadable == true and not invokeErr then return nil, "无容器" end

    -- 兼容不支持整面返回的版本：退回原来的逐罐路径。
    local count, err = transposer.tanks(address, side)
    if not count then return nil, err end

    -- 单罐形状：{ amount=, capacity=, id=, label=, name= }；空罐没有 name。
    local out = {}
    for tank = 1, count do
        local info = device.invoke(address, "getFluidInTank", side, tank)
        out[#out + 1] = tankEntry(tank, info)
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

--- ItemStackArrayValue -> 本项目的物品条目数组
-- @param value table|userdata getAllStacks 返回值
-- @return table|nil
local function allStacksEntries(value)
    if value == nil then return nil end
    local ok, all = pcall(function() return value:getAll() end)
    if not ok or type(all) ~= "table" then return nil end

    -- ItemStackArrayValue.getAll 使用 0 基键；未来若改成 1 基也按最小键自动兼容。
    local base = (all[0] ~= nil) and 1 or 0
    local out = {}
    for index, stack in pairs(all) do
        local slot = tonumber(index)
        if slot and type(stack) == "table" and stack.name then
            out[#out + 1] = {
                slot    = slot + base,
                name    = stack.name,
                damage  = tonumber(stack.damage) or 0,
                label   = stack.label,
                size    = tonumber(stack.size) or 0,
                maxSize = tonumber(stack.maxSize) or 64
            }
        end
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end

--- 该面非空物品槽（含 name / damage / label / size / maxSize）
-- @param address string 转运器地址
-- @param side number 面
-- @param knownSize number|nil 调用方已经读过库存大小时传入，避免重复 getInventorySize
-- @return table|nil { {slot=, name=, damage=, label=, size=, maxSize=}, ... }
-- @return string|nil
function transposer.items(address, side, knownSize)
    if allStacksReadable ~= false then
        local value, valueErr = device.invoke(address, "getAllStacks", side)
        local fast = allStacksEntries(value)
        if fast then
            allStacksReadable = true
            return fast, nil
        end
        -- 明确不支持时后续直接走逐槽，避免每个面多打一次失败调用。
        if value == nil and valueErr and valueErr:find("no such method", 1, true) then
            allStacksReadable = false
        end
    end

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

--- 只统计某个物品的数量；达到 limit 就提前停止，避免无脑扫完整库存。
-- @param address string 转运器地址
-- @param side number 面
-- @param name string 物品注册名
-- @param damage number|nil 物品 damage
-- @param limit number|nil 够用即停的上限
-- @return number 数量（最多到 limit）
-- @return string|nil 失败原因
function transposer.itemCount(address, side, name, damage, limit)
    local items, err = transposer.items(address, side)
    if not items then return 0, err end
    local total = 0
    local wantDamage = tonumber(damage) or 0
    for _, stack in ipairs(items) do
        if stack.name == name and stack.damage == wantDamage then
            total = total + stack.size
            if type(limit) == "number" and limit > 0 and total >= limit then break end
        end
    end
    return total, nil
end

--- 找第一个匹配的物品槽；只扫到命中即停。
-- @param address string 转运器地址
-- @param side number 面
-- @param name string 物品注册名
-- @param damage number|nil 物品 damage
-- @return number|nil 槽（1 基）
-- @return number 堆叠数
function transposer.findItem(address, side, name, damage)
    local items, err = transposer.items(address, side)
    if not items then return nil, 0, err end
    local wantDamage = tonumber(damage) or 0
    for _, stack in ipairs(items) do
        if stack.name == name and stack.damage == wantDamage then
            return stack.slot, stack.size, nil
        end
    end
    return nil, 0, nil
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
