--------------------------------------------------------------------------------
-- backend/app/produce_job.lua
--------------------------------------------------------------------------------
-- 【职责】domain operation 的 ctx：传感器、源缓存、分批转运、状态查询
-- 【不做什么】不直接碰组件；action 由 produce/executor 执行
--------------------------------------------------------------------------------

local CONFIG   = require("shared.config")
local state    = require("shared.state")
local executor = require("backend.app.produce.executor")

local job = {}

local function activeFact(machine, level)
    for _, fact in ipairs(state.read.plant(level).machines or {}) do
        if fact.address == machine then return fact.active == true end
    end
    return false
end

local function newContext(machine, sub)
    local ctx = {
        machine = machine,
        level = sub.level,
        sources = {},
        itemSource = nil,
        itemReturnSide = nil,
        trace = { order = {}, byKey = {} },
        limit = math.max(1, math.floor((tonumber(sub.rate) or 0)
            * (tonumber(CONFIG.PRODUCE.CHUNK_RATIO) or 0.05)))
    }

    local function recordTransfer(kind, name, label, amount)
        amount = math.floor(tonumber(amount) or 0)
        if amount <= 0 then return end
        local key = kind .. ":" .. tostring(name)
        local entry = ctx.trace.byKey[key]
        if not entry then
            entry = { kind = kind, label = label or name, amount = 0 }
            ctx.trace.byKey[key] = entry
            ctx.trace.order[#ctx.trace.order + 1] = entry
        end
        entry.amount = entry.amount + amount
    end

    ctx.sensor = function()
        local result = ctx.action({ kind = "sensor" })
        if not result or not result.ok then return nil, result and result.reason or "传感器失败" end
        return result.lines, nil
    end

    --- 按需解析传感器字段；field=nil 返回 parallel+success
    ctx.sensorInfo = function(field)
        local result = ctx.action({ kind = "sensor", field = field })
        if not result or not result.ok then return nil, result and result.reason or "传感器失败" end
        return result.value, nil
    end

    ctx.active = function() return activeFact(machine, sub.level) end

    local function sourceFor(fluid, label)
        local source = ctx.sources[fluid]
        if source then return source end
        local result = ctx.action({ kind = "findFluid", fluid = fluid, label = label })
        if not result or not result.ok then
            return nil, result and result.reason
                or ("找不到源流体：" .. tostring(label or fluid))
        end
        ctx.sources[fluid] = result.source
        return result.source, nil
    end

    local function transferFluid(fluid, amount, label)
        amount = tonumber(amount) or 0
        label  = tostring(label or fluid)
        local remaining = amount
        while remaining > 0 do
            local source, why = sourceFor(fluid, label)
            if not source then return false, why end
            if source.available < remaining then
                return false, string.format("%s 可用量不足：%d/%d mB",
                    label, source.available, remaining)
            end
            local request = math.min(remaining, ctx.limit, source.amount)
            local result = ctx.action({
                kind = "transferFluid", source = source, amount = request, label = label
            })
            local moved = (result and result.ok) and tonumber(result.moved) or 0
            if moved ~= request then
                ctx.sources[fluid] = nil
                return false, string.format("%s 转运不完整：%d/%d mB（%s）",
                    label, moved, request, result and result.reason or "失败")
            end
            recordTransfer("fluid", fluid, label, moved)
            remaining = remaining - moved
            source.amount = source.amount - moved
            source.available = source.available - moved
            if source.amount <= 0 then ctx.sources[fluid] = nil end
        end
        return true, nil
    end

    ctx.transferFluid = function(fluid, amount, label)
        return transferFluid(fluid, amount, label)
    end

    ctx.transferAny = function(anyList, amount, label)
        label = tostring(label or "候选流体")
        local result = ctx.action({
            kind = "findAny", any = anyList, amount = amount, label = label
        })
        if not result or not result.ok then
            return false, result and result.reason or ("找不到候选流体：" .. label)
        end
        ctx.sources[result.source.fluid] = result.source
        return transferFluid(result.source.fluid, amount, label)
    end

    ctx.transferItem = function(required, amount)
        amount = tonumber(amount) or 0
        local remaining = amount
        local source = ctx.itemSource
        while remaining > 0 do
            if source and source.item ~= required then source, ctx.itemSource = nil, nil end
            if not source then
                local result = ctx.action({ kind = "findItem", item = required })
                if not result or not result.ok then
                    return false, result and result.reason
                        or ("找不到物品源：" .. tostring(required.label or required.name))
                end
                source, ctx.itemSource = result.source, result.source
            end
            ctx.itemReturnSide = source.side
            local request = math.min(remaining, source.count)
            local result = ctx.action({
                kind = "transferItem", source = source, amount = request,
                label = required.label or required.name
            })
            local moved = (result and result.ok) and tonumber(result.moved) or 0
            if moved <= 0 then
                ctx.itemSource = nil
                return false, result and result.reason
                    or ((required.label or required.name) .. " 转运失败")
            end
            recordTransfer("item", required.name .. ":" .. (tonumber(required.damage) or 0),
                required.label or required.name, moved)
            remaining = remaining - moved
            source.count = source.count - moved
            if source.count <= 0 then source, ctx.itemSource = nil, nil end
        end
        return true, nil
    end

    --- 把刚投入目标侧的物品送回原来源侧
    ctx.returnItem = function(required)
        local result = ctx.action({
            kind = "returnItem",
            item = required,
            to = ctx.itemReturnSide
        })
        if not result or not result.ok then
            return false, result and result.reason or "物品回收失败"
        end
        local moved = tonumber(result.moved) or 0
        if moved <= 0 then return false, "物品未移动" end
        recordTransfer("item", required.name .. ":" .. (tonumber(required.damage) or 0),
            required.label or required.name, moved)
        return true, nil
    end

    --- 回收目标侧所有残留物品（T6 每周期起点调用）
    ctx.recoverTarget = function()
        local result = ctx.action({ kind = "recoverTarget" })
        if not result or not result.ok then
            return false, result and result.reason or "目标侧残留回收失败"
        end
        for _, item in ipairs(result.moved or {}) do
            recordTransfer("item",
                item.name .. ":" .. (tonumber(item.damage) or 0),
                item.label or item.name, item.amount)
        end
        return true, nil
    end

    return ctx
end

function job.new(machine, sub, operation, recoversTargetItems)
    local ctx = newContext(machine, sub)
    return {
        machine = machine,
        level = sub.level,
        sub = sub,
        operation = function()
            -- T6 会先回收目标侧残留，因此允许它跳过通用空目标检查。
            if not recoversTargetItems then
                local result = ctx.action({ kind = "target" })
                if not result or not result.ok then
                    return false, result and result.reason or "输出侧检查失败"
                end
            end
            return operation(ctx)
        end,
        ctx = ctx,
        executor = executor.run
    }
end

return job
