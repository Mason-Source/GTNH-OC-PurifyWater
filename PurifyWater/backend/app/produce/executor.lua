--------------------------------------------------------------------------------
-- backend/app/produce/executor.lua
--------------------------------------------------------------------------------
-- 【职责】operation action -> 硬件调用；源扫描与目标/源解析
-- 【不做什么】不认识 Tn 业务，不维护 coroutine
--------------------------------------------------------------------------------

local probes       = require("backend.hardware.probes")
local gtInfodata   = require("backend.hardware.gt_infodata")
local transposer   = require("backend.hardware.transposer")

local executor = {}

--- 扫描所有输入流体面，按流体聚合
local function scanFluids(sub)
    local out = {}
    for _, side in ipairs((sub.sides and sub.sides.sources) or {}) do
        for _, item in ipairs(transposer.containers(sub.transposer, side) or {}) do
            local amount = tonumber(item.amount) or 0
            local fluid = item.fluid
            if fluid and amount > 0 then
                local entry = out[fluid]
                if entry then
                    entry.available = entry.available + amount
                    if amount > entry.amount then
                        entry.side, entry.tank, entry.amount = side, item.tank, amount
                    end
                else
                    out[fluid] = {
                        fluid = fluid, side = side, tank = item.tank,
                        amount = amount, available = amount
                    }
                end
            end
        end
    end
    return out
end

--- 从候选流体中选一个可用源
local function findAnySource(sub, anyList, need)
    local found = scanFluids(sub)
    local best, enough
    for _, fluid in ipairs(anyList or {}) do
        local entry = found[fluid]
        if entry then
            if not best or entry.available > best.available then best = entry end
            if (not need or entry.available >= need)
                and (not enough or entry.available > enough.available) then
                enough = entry
            end
        end
    end
    return enough or best
end

--- 找物品源槽
local function findItemSource(sub, required)
    for _, side in ipairs((sub.sides and sub.sides.itemSources) or {}) do
        local slot, size = transposer.findItem(sub.transposer, side, required.name, required.damage)
        if slot and size > 0 then
            return { side = side, slot = slot, count = size, item = required }
        end
    end
end

--- 优先回到已有同名物品的来源面，其次回第一个来源面
local function itemSourceSide(sub, item)
    local source = findItemSource(sub, item)
    if source then return source.side end
    return ((sub.sides and sub.sides.itemSources) or {})[1]
end

local function validItemSourceSide(sub, side)
    for _, candidate in ipairs((sub.sides and sub.sides.itemSources) or {}) do
        if candidate == side then return side end
    end
end

local HANDLERS = {}

HANDLERS.sensor = function(action, job)
    local lines, err = probes.sensorLines(job.machine)
    if not lines then return { ok = false, reason = err or "传感器读取失败" } end
    local value
    if action.field ~= nil then
        value, err = gtInfodata.extract(lines, action.field)
        if err then return { ok = false, reason = err } end
    end
    return { ok = true, lines = lines, value = value }
end

HANDLERS.target = function(action, job)
    local sub = job.sub
    if not sub.sides then return { ok = false, reason = "侧位未配置" } end
    if sub.sides.target then
        for _, item in ipairs(transposer.containers(sub.transposer, sub.sides.target) or {}) do
            if item.fluid and (tonumber(item.amount) or 0) > 0 then
                return { ok = false, reason = "输出侧有流体残留，请先清空目标容器" }
            end
        end
    end
    if sub.sides.itemTarget then
        local items = transposer.items(sub.transposer, sub.sides.itemTarget)
        if items and #items > 0 then
            return { ok = false, reason = "输出侧物品残留" }
        end
    end
    return { ok = true }
end

HANDLERS.findFluid = function(action, job)
    local source = scanFluids(job.sub)[action.fluid]
    if not source then
        return { ok = false, reason = "找不到源流体：" .. tostring(action.label or action.fluid) }
    end
    return { ok = true, source = source }
end

HANDLERS.findAny = function(action, job)
    local source = findAnySource(job.sub, action.any, action.amount)
    if not source then
        return { ok = false, reason = "找不到候选流体：" .. tostring(action.label or "未知候选组") }
    end
    return { ok = true, source = source }
end

HANDLERS.findItem = function(action, job)
    local source = findItemSource(job.sub, action.item)
    if not source then
        return { ok = false, reason = "找不到物品源：" .. tostring(action.item.label or action.item.name) }
    end
    return { ok = true, source = source }
end

HANDLERS.transferFluid = function(action, job)
    local sub = job.sub
    if not sub.sides or not sub.sides.target then
        return { ok = false, reason = "没有流体目标侧" }
    end
    local ok, moved = transposer.transfer(sub.transposer, action.source.side,
        sub.sides.target, action.amount, action.source.tank)
    if not ok then
        return { ok = false, reason = tostring(action.label or action.source.fluid)
            .. " 转运失败：" .. tostring(moved or "未知原因") }
    end
    return { ok = true, moved = tonumber(moved) or 0 }
end

HANDLERS.transferItem = function(action, job)
    local sub = job.sub
    if not sub.sides or not sub.sides.itemTarget then
        return { ok = false, reason = "没有物品目标侧" }
    end
    local ok, moved = transposer.transferItems(sub.transposer, action.source.side,
        sub.sides.itemTarget, action.amount, action.source.slot)
    if not ok then
        return { ok = false, reason = tostring(action.label
            or action.source.item.label or action.source.item.name)
            .. " 转运失败：" .. tostring(moved or "未知原因") }
    end
    return { ok = true, moved = tonumber(moved) or 0 }
end

HANDLERS.returnItem = function(action, job)
    local sub = job.sub
    if not sub.sides or not sub.sides.itemTarget then
        return { ok = false, reason = "没有物品目标侧" }
    end
    local to = validItemSourceSide(sub, action.to)
        or itemSourceSide(sub, action.item)
    if to == nil then return { ok = false, reason = "没有可回收的物品来源侧" } end

    local slot, count, err = transposer.findItem(sub.transposer, sub.sides.itemTarget,
        action.item.name, action.item.damage)
    if not slot then
        return { ok = false, reason = err
            or ("目标侧找不到物品：" .. tostring(action.item.label or action.item.name)) }
    end
    local amount = math.min(tonumber(action.amount) or 1, count)
    local ok, moved = transposer.transferItems(sub.transposer, sub.sides.itemTarget,
        to, amount, slot)
    if not ok then return { ok = false, reason = tostring(moved or "物品回收失败") } end
    return { ok = true, moved = tonumber(moved) or 0 }
end

HANDLERS.recoverTarget = function(action, job)
    local sub = job.sub
    if not sub.sides or not sub.sides.itemTarget then
        return { ok = false, reason = "没有物品目标侧" }
    end
    if #((sub.sides and sub.sides.itemSources) or {}) == 0 then
        return { ok = false, reason = "没有可回收的物品来源侧" }
    end

    local items, err = transposer.items(sub.transposer, sub.sides.itemTarget)
    if not items then return { ok = false, reason = tostring(err or "目标侧物品读取失败") } end

    local movedOut = {}
    for _, stack in ipairs(items) do
        local item = { name = stack.name, damage = stack.damage }
        local to = itemSourceSide(sub, item)
        if to == nil then return { ok = false, reason = "没有可回收的物品来源侧" } end

        local ok, moved = transposer.transferItems(sub.transposer, sub.sides.itemTarget,
            to, stack.size, stack.slot)
        if not ok or tonumber(moved) ~= stack.size then
            return { ok = false, reason = string.format("残留物品回收不完整：%s %s/%d",
                tostring(stack.label or stack.name), tostring(moved or "-"), stack.size) }
        end
        movedOut[#movedOut + 1] = {
            name = stack.name,
            damage = stack.damage,
            label = stack.label,
            amount = moved
        }
    end
    return { ok = true, moved = movedOut }
end

--- 执行一个 action
function executor.run(action, job)
    local handler = HANDLERS[action and action.kind]
    if not handler then
        return { ok = false, reason = "未知 action：" .. tostring(action and action.kind) }
    end
    return handler(action, job)
end

return executor
