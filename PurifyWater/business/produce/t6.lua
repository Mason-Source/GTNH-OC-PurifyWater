-- T6 紫外处理：按请求签名顺序更换 9 种透镜。
local resources = require("shared.resources")
local machine = require("business.produce.machine")

local WAIT = 3
local MAX_PROBES = 6
local LENSES = {
    resources.ITEMS.LENS_SYNTHETIC_JADE,
    resources.ITEMS.LENS_AMBER,
    resources.ITEMS.LENS_WIND_MAGIC_CRYSTAL,
    resources.ITEMS.LENS_EMERALD,
    resources.ITEMS.LENS_MAGIC_DIAMOND,
    resources.ITEMS.LENS_BLUE_TOPAZ,
    resources.ITEMS.LENS_AMETHYST,
    resources.ITEMS.LENS_FLUORINE_IRON_TOURMALINE,
    resources.ITEMS.LENS_DILITHIUM,
}
local REQUIRED = {}
for index = 1, #LENSES - 1 do REQUIRED[index] = LENSES[index] end

local t6 = {
    level = 6,
    LENSES = LENSES,
    priority = 6,
    initial = "recover_read",
}

function t6.requiredItems() return REQUIRED end

function t6.build()
    return {
        state = "recover_read",
        lensIndex = 1,
        requestAttempts = 0,
        sourceIndex = 1,
    }
end

local function sameItem(stack, item)
    return stack.name == item.name and (tonumber(stack.damage) or 0) == (tonumber(item.damage) or 0)
end

local function signatureOf(event)
    if not event or not event.ok then return nil, tostring(event and event.err or "透镜需求不可读") end
    local signature = tostring(event.value or "")
    if signature == "" then return nil, "透镜需求签名为空" end
    return signature, nil
end

local function targetAndSources(task)
    local sides = task.entry.sides or {}
    return sides.itemTarget, sides.itemSources or {}
end

local function readTarget(task)
    local target = targetAndSources(task)
    if target == nil then return machine.fail("没有物品目标侧") end
    return machine.command("readItems", { side = target }, task.state)
end

t6.states = {
    recover_read = function(task, event, _, _)
        if event == nil then return readTarget(task) end
        if not event.ok then
            return machine.fail("目标侧读取失败：" .. tostring(event.err),
                { kind = "item", code = "TARGET_INVALID", side = targetAndSources(task) })
        end
        local items = event.items or {}
        if #items == 0 then
            task.nextProbeAt = 0
            task.requestAttempts = 0
            return machine.jump("request_read")
        end
        task.recoverStack = items[1]
        return machine.jump("recover_move")
    end,

    recover_move = function(task, event, _, _)
        local target, sources = targetAndSources(task)
        if event == nil then
            if target == nil then return machine.fail("没有物品目标侧") end
            local to = sources[1]
            if to == nil then return machine.fail("没有可回收的物品来源侧") end
            local stack = task.recoverStack
            if not stack then return machine.fail("T6 缺少待回收残留") end
            return machine.command("transferItem", {
                from = target, to = to, count = stack.size, slot = stack.slot,
            }, "recover_move")
        end
        local stack = task.recoverStack
        if not event.ok or tonumber(event.moved) ~= tonumber(stack.size) then
            return machine.fail("目标侧残留回收失败：" .. tostring(event.err or event.moved),
                { kind = "item", code = "RETURN_NOT_MOVED", item = stack, amount = stack.size })
        end
        task.recoverStack = nil
        return machine.jump("recover_read")
    end,

    request_read = function(task, event, now, _)
        if event == nil then
            if now < (task.nextProbeAt or 0) then
                return machine.wait(task.nextProbeAt - now, "request_read")
            end
            return machine.command("sensor", { field = "lensRequest" }, "request_read")
        end
        local signature, err = signatureOf(event)
        if signature then
            task.signature = signature
            task.lensIndex = 1
            task.currentLens = nil
            task.sourceIndex = 1
            return machine.jump("lens_find")
        end
        task.requestAttempts = (task.requestAttempts or 0) + 1
        if task.requestAttempts >= MAX_PROBES then
            return machine.fail("读取初始透镜需求失败：" .. tostring(err))
        end
        task.nextProbeAt = now + WAIT
        return machine.wait(WAIT, "request_read")
    end,

    wait_request = function(task, event, now, _)
        if event == nil then
            if now < (task.nextProbeAt or 0) then
                return machine.wait(task.nextProbeAt - now, "wait_request")
            end
            return machine.command("sensor", { field = "lensRequest" }, "wait_request")
        end
        local signature, err = signatureOf(event)
        if signature and signature ~= task.signature then
            task.nextSignature = signature
            task.currentLens = LENSES[task.lensIndex]
            task.lensIndex = task.lensIndex + 1
            return machine.jump("return_find")
        end
        task.requestAttempts = (task.requestAttempts or 0) + 1
        if task.requestAttempts >= MAX_PROBES then
            return machine.fail(string.format("等待第 %d 枚透镜需求变化失败：%s；%s 保留在目标侧",
                task.lensIndex + 1, tostring(err or "需求未变化"), LENSES[task.lensIndex].label))
        end
        task.nextProbeAt = now + WAIT
        return machine.wait(WAIT, "wait_request")
    end,

    return_find = function(task, event, _, _)
        if event == nil then return readTarget(task) end
        if not event.ok then
            return machine.fail("目标侧读取失败：" .. tostring(event.err),
                { kind = "item", code = "TARGET_INVALID", side = targetAndSources(task) })
        end
        task.returnSlot, task.returnSize = nil, nil
        for _, stack in ipairs(event.items or {}) do
            if sameItem(stack, task.currentLens) then
                task.returnSlot, task.returnSize = stack.slot, stack.size
                break
            end
        end
        task.sourceIndex = 1
        if task.returnSlot then return machine.jump("return_move") end
        return machine.jump("lens_find")
    end,

    return_move = function(task, event, _, _)
        local target, sources = targetAndSources(task)
        if event == nil then
            if target == nil then return machine.fail("没有物品目标侧") end
            local to = sources[1]
            if to == nil then return machine.fail("没有可回收的物品来源侧") end
            return machine.command("transferItem", {
                from = target, to = to, count = task.returnSize, slot = task.returnSlot,
            }, "return_move")
        end
        task.sourceIndex = 1
        return machine.jump("lens_find")
    end,

    lens_find = function(task, event, _, _)
        local _, sources = targetAndSources(task)
        local side = sources[task.sourceIndex]
        if side == nil then
            if task.lensIndex == #LENSES then return machine.done() end
            return machine.fail("找不到物品源：" .. tostring(LENSES[task.lensIndex].label))
        end
        if event == nil then
            return machine.command("readItems", { side = side }, "lens_find")
        end
        if not event.ok then
            return machine.fail("物品来源读取失败：" .. tostring(event.err),
                { kind = "item", code = "SOURCE_INVALID", side = side })
        end
        task.foundSlot, task.foundSize = nil, nil
        local lens = LENSES[task.lensIndex]
        for _, stack in ipairs(event.items or {}) do
            if sameItem(stack, lens) then
                task.foundSlot, task.foundSize = stack.slot, stack.size
                break
            end
        end
        if task.foundSlot then return machine.jump("lens_move") end
        task.sourceIndex = task.sourceIndex + 1
        return machine.jump("lens_find")
    end,

    lens_move = function(task, event, now, _)
        local target, sources = targetAndSources(task)
        local side = sources[task.sourceIndex]
        local lens = LENSES[task.lensIndex]
        if event == nil then
            if side == nil or target == nil then return machine.fail("T6 缺少透镜来源侧或目标侧") end
            return machine.command("transferItem", {
                from = side, to = target, count = 1, slot = task.foundSlot,
            }, "lens_move")
        end
        if not event.ok or (tonumber(event.moved) or 0) < 1 then
            if task.lensIndex == #LENSES then return machine.done() end
            return machine.fail(string.format("%s 投放失败：%s", lens.label, tostring(event.err or event.moved)),
                { kind = "item", code = "ITEM_NOT_MOVED", item = lens, side = side,
                  target = target, amount = 1 })
        end
        if task.lensIndex == #LENSES then return machine.done() end
        if task.nextSignature then task.signature = task.nextSignature end
        task.nextSignature = nil
        task.requestAttempts = 0
        task.nextProbeAt = now + WAIT
        return machine.wait(WAIT, "wait_request")
    end,
}

return t6