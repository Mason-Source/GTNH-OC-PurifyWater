-- 流体/物品转运子流程：只生成命令和消费命令结果，不直接调用组件。
local machine = require("business.produce.machine")

local flow = {}

local function recordUsage(task, key, label, amount, unit)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    task.usage = task.usage or {}
    task.usageOrder = task.usageOrder or 0
    local item = task.usage[key]
    if not item then
        task.usageOrder = task.usageOrder + 1
        item = { label = label, unit = unit, amount = 0, order = task.usageOrder }
        task.usage[key] = item
    end
    item.amount = item.amount + amount
end

local function copySources(list)
    local out = {}
    for _, source in ipairs(list or {}) do out[#out + 1] = source end
    return out
end

local function fluidSources(task, spec)
    local slots = task.entry.slots and task.entry.slots.fluid or {}
    local out = {}
    if spec.any then
        for _, id in ipairs(spec.any) do
            for _, source in ipairs(slots[id] or {}) do
                out[#out + 1] = { side = source.side, tank = source.tank, fluid = id }
            end
        end
    else
        for _, source in ipairs(slots[spec.id] or {}) do
            out[#out + 1] = { side = source.side, tank = source.tank, fluid = spec.id }
        end
    end
    return out
end

local function itemKey(item)
    return tostring(item.name) .. ":" .. tostring(tonumber(item.damage) or 0)
end

local function itemSources(task, item)
    local slots = task.entry.slots and task.entry.slots.item or {}
    return copySources(slots[itemKey(item)] or {})
end

local function fatal(code)
    return code == "ENERGY" or code == "SIDE_MISSING"
end

function flow.fluid(key, task, event, spec, amount, target, env, nextState)
    local io = task[key]
    if not io then
        io = {
            remaining = tonumber(amount) or 0,
            sources = fluidSources(task, spec),
            index = 1,
            label = tostring(spec.short or spec.label or spec.id or "候选流体"),
            lastFailure = nil,
        }
        task[key] = io
        if io.remaining <= 0 then task[key] = nil; return nil, true end
    end

    if target == nil then
        task[key] = nil
        return machine.fail("没有流体目标侧", {
            kind = "fluid", code = "SIDE_MISSING", fluid = spec.id, any = spec.any,
            amount = io.remaining, label = io.label,
        })
    end

    if event then
        if event.ok and tonumber(event.moved) and tonumber(event.moved) > 0 then
            recordUsage(task, "fluid:" .. tostring(spec.id or spec.label), io.label, tonumber(event.moved), "fluid")
            io.remaining = io.remaining - tonumber(event.moved)
            if io.remaining <= 0 then task[key] = nil; return nil, true end
        else
            local raw = tostring(event.err or "转运失败")
            local code = event.code or "FLUID_NOT_MOVED"
            local source = io.sources[io.index] or {}
            local failure = {
                kind = "fluid", code = code, fluid = source.fluid or spec.id, any = spec.any,
                side = source.side, tank = source.tank, target = target,
                amount = math.min(io.remaining, env.chunkLimit()), raw = raw, label = io.label,
            }
            if fatal(code) then
                task[key] = nil
                return machine.fail(io.label .. " 转运失败：" .. raw, failure)
            end
            io.lastFailure = failure
            io.index = io.index + 1
        end
    end

    local source = io.sources[io.index]
    if not source then
        local failure = io.lastFailure or {
            kind = "fluid", code = "FLUID_TANK_MISSING", fluid = spec.id, any = spec.any,
            amount = io.remaining, label = io.label,
        }
        task[key] = nil
        return machine.fail(io.label .. " 来源罐不可用", failure)
    end

    local request = math.min(io.remaining, env.chunkLimit())
    return machine.command("transferFluid", {
        from = source.side, to = target, amount = request,
        tank = source.tank, label = io.label,
    }, nextState or task.state)
end

function flow.item(key, task, event, item, amount, target, nextState)
    local io = task[key]
    if not io then
        io = {
            remaining = tonumber(amount) or 0,
            sources = itemSources(task, item),
            index = 1,
            item = item,
            label = tostring(item.short or item.label or item.name or "物品"),
            lastFailure = nil,
        }
        task[key] = io
        if io.remaining <= 0 then task[key] = nil; return nil, true end
    end

    if target == nil then
        task[key] = nil
        return machine.fail("没有物品目标侧", {
            kind = "item", code = "SIDE_MISSING", item = item, amount = io.remaining,
        })
    end

    if event then
        if event.ok and tonumber(event.moved) and tonumber(event.moved) > 0 then
            recordUsage(task, "item:" .. itemKey(item), io.label, tonumber(event.moved), "")
            io.remaining = io.remaining - tonumber(event.moved)
            if io.remaining <= 0 then task[key] = nil; return nil, true end
        else
            local raw = tostring(event.err or "物品转运失败")
            local code = event.code or "ITEM_NOT_MOVED"
            local source = io.sources[io.index] or {}
            local failure = {
                kind = "item", code = code, item = item, side = source.side,
                slot = source.slot, target = target, amount = io.remaining, raw = raw,
            }
            if fatal(code) then
                task[key] = nil
                return machine.fail(tostring(item.label or item.name) .. " 转运失败：" .. raw, failure)
            end
            io.lastFailure = failure
            io.index = io.index + 1
        end
    end

    local source = io.sources[io.index]
    if not source then
        local failure = io.lastFailure or {
            kind = "item", code = "ITEM_SLOT_MISSING", item = item, amount = io.remaining,
        }
        task[key] = nil
        return machine.fail("找不到物品来源槽：" .. tostring(item.label or item.name), failure)
    end

    return machine.command("transferItem", {
        from = source.side, to = target, count = io.remaining, slot = source.slot,
    }, nextState or task.state)
end

return flow