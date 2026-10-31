-- 制作任务运行时：周期登记、门控、单步状态推进；每步最多一次组件调用。
local CONFIG = require("shared.config")
local constants = require("shared.constants")
local state = require("services.state")
local log = require("services.log")
local control = require("services.control")
local clock = require("services.clock")
local probes = require("hardware.probes")
local gt_infodata = require("hardware.gt_infodata")
local transposer = require("hardware.transposer")
local machines = require("hardware.machines")
local util = require("shared.util")
local produce = require("business.produce")
local machine = require("business.produce.machine")
local produce_service = require("services.produce_service")

local runtime = {}

local function data()
    return state.get()
end

local function store()
    return data().work.produce
end

local function machineText(level, address)
    for _, item in ipairs(machines.of(level)) do
        if item.address == address and type(item.x) == "number"
            and type(item.y) == "number" and type(item.z) == "number" then
            return string.format("(%d,%d,%d)", item.x, item.y, item.z)
        end
    end
    return util.shortAddress(address)
end

local function entryActive(entry)
    for _, current in ipairs(data().produce.bindings or {}) do
        if current == entry then return true end
    end
    return false
end

local function machineActive(address)
    local fact = data().facts.machines[address]
    return fact ~= nil and fact.active == true
end

local function transferCode(raw, fallback)
    local text = tostring(raw or ""):lower()
    if text:find("energy", 1, true) or text:find("能量", 1, true) then return "ENERGY" end
    if text:find("no inventory", 1, true) or text:find("no tank", 1, true)
        or text:find("target", 1, true) or text:find("side", 1, true) then
        return "SIDE_MISSING"
    end
    return fallback
end

local function chunkLimit(task)
    local rate = tonumber(task.entry.rate) or 0
    return math.max(1, math.floor(rate * (CONFIG.PRODUCE.CHUNK_RATIO or 0.05)))
end

local function executeCommandNow(task, command)
    if command.kind == "sensor" then
        local info, err = probes.sensor(task.machine)
        if not info then return { ok = false, err = err or "传感器读取失败" } end
        if command.field == nil then return { ok = true, info = info, lines = info.lines } end
        local value, fieldErr = gt_infodata.extract(info.lines, command.field)
        if value == nil then
            return { ok = false, err = fieldErr or ("传感器字段不可读：" .. tostring(command.field)) }
        end
        return { ok = true, value = value }
    end

    if command.kind == "readItems" then
        local items, err = transposer.items(task.entry.transposer, command.side)
        if not items then return { ok = false, err = err or "物品读取失败" } end
        return { ok = true, items = items }
    end

    if command.kind == "transferFluid" then
        local ok, moved = transposer.transferFluid(task.entry.transposer, command.from,
            command.to, command.amount, command.tank)
        if ok and tonumber(moved) and tonumber(moved) > 0 then
            return { ok = true, moved = tonumber(moved) }
        end
        local raw = tostring(moved or "流体转运失败")
        return { ok = false, err = raw, code = transferCode(raw, "FLUID_NOT_MOVED") }
    end

    if command.kind == "transferItem" then
        local ok, moved = transposer.transferItem(task.entry.transposer, command.from,
            command.to, command.count, command.slot)
        if ok and tonumber(moved) and tonumber(moved) > 0 then
            return { ok = true, moved = tonumber(moved) }
        end
        local raw = tostring(moved or "物品转运失败")
        return { ok = false, err = raw, code = transferCode(raw, "ITEM_NOT_MOVED") }
    end

    return { ok = false, err = "未知制作命令：" .. tostring(command.kind), code = "COMMAND_INVALID" }
end

local function executeCommand(task, command)
    local startedAt = clock.uptime()
    local result = executeCommandNow(task, command)
    local finishedAt = clock.uptime()
    result.startedAt = startedAt
    result.finishedAt = finishedAt
    result.elapsed = math.max(0, finishedAt - startedAt)
    task.lastCommand = command.kind
    task.lastResultAt = finishedAt
    task.lastResult = {
        ok = result.ok == true,
        err = result.err,
        moved = result.moved,
        value = result.value,
        items = result.items and #result.items or nil,
        startedAt = startedAt,
        finishedAt = finishedAt,
        elapsed = result.elapsed,
    }
    return result
end
local function canRun(task)
    if task.cycleSeq ~= data().facts.host.cycle.seq then return false, "周期已变化" end
    if not entryActive(task.entry) then return false, "绑定已失效" end
    if not machineActive(task.machine) then return false, "机器未运行" end
    return produce_service.canRunBinding(task.entry)
end

local function remove(id)
    store().tasks[id] = nil
end

local function usageText(task)
    local list = {}
    for _, item in pairs(task.usage or {}) do list[#list + 1] = item end
    table.sort(list, function(a, b) return (a.order or 0) < (b.order or 0) end)
    local parts = {}
    for _, item in ipairs(list) do
        local amount = util.formatShortNumber(item.amount or 0)
        if item.unit == "fluid" then
            parts[#parts + 1] = item.label .. " " .. util.formatVolume(item.amount)
        else
            parts[#parts + 1] = string.format("%s×%s", item.label, amount)
        end
    end
    return table.concat(parts, "、")
end

local function remember(task, status, at, reason)
    store().last = {
        id = task.id,
        level = task.level,
        machine = task.machine,
        state = task.state,
        status = status,
        expectedAt = task.expectedAt,
        completedAt = at,
        reason = reason,
        lastResult = task.lastResult,
    }
end

local function complete(task, at)
    at = at or clock.uptime()
    task.completedAt = at
    remember(task, "done", at)
    remove(task.id)
    local used = usageText(task)
    log.system(string.format("%s 制作完成%s", constants.levelCode(task.level),
        used ~= "" and ("：" .. used) or ""))
end

local function fail(task, reason, failure, at)
    at = at or clock.uptime()
    task.failedAt = at
    remember(task, "failed", at, tostring(reason))
    remove(task.id)
    log.warn(string.format("%s 制作失败：%s（机器 %s）",
        constants.levelCode(task.level), tostring(reason), machineText(task.level, task.machine)))
    if failure then produce_service.onTransferFailure(task.machine, failure) end
end

local function cancelAll()
    store().tasks = {}
end

local function pickDue(now)
    local picked
    for _, task in pairs(store().tasks) do
        if task.runAt <= now then
            if not picked or task.priority < picked.priority
                or (task.priority == picked.priority and task.runAt < picked.runAt) then
                picked = task
            end
        end
    end
    return picked
end

local function addTask(entry, method, seq, now)
    local id = string.format("produce:%d:%s", entry.level, entry.machine)
    if store().tasks[id] then return end
    local task = machine.create(method, entry, now)
    task.id = id
    task.machine = entry.machine
    task.entry = entry
    task.level = entry.level
    task.priority = tonumber(method.priority) or 100
    task.cycleSeq = seq
    task.runAt = now
    task.expectedAt = now
    task.createdAt = now

    store().tasks[id] = task
end

local function spawnCycle(seq, now)
    if seq <= 0 or not control.isRunning(data()) then return end
    local progress = tonumber(data().facts.host.progress.value)
    local maxProgress = tonumber(data().facts.host.progressMax.value)
    if progress and maxProgress and maxProgress > 0
        and progress / maxProgress > (CONFIG.PRODUCE.CYCLE_CUTOFF or 0.9) then
        return
    end
    for _, entry in ipairs(data().produce.bindings or {}) do
        local method = produce.method(entry.level)
        local product = data().produce.levels[entry.level] or {}
        if method and product.enabled == true and machineActive(entry.machine) then
            local ok = produce_service.canRunBinding(entry)
            if ok then addTask(entry, method, seq, now) end
        end
    end
end

function runtime.load()
    store().tasks = {}
    store().activeCycle = data().facts.host.cycle.seq or 0
end

function runtime.nextDue(now)
    local slot = store()
    if not control.isRunning(data()) then
        if next(slot.tasks or {}) ~= nil then return now end
        return math.huge
    end
    if (data().facts.host.cycle.seq or 0) ~= slot.activeCycle then return now end
    local best = math.huge
    for _, task in pairs(slot.tasks or {}) do
        if task.runAt < best then best = task.runAt end
    end
    return best
end

function runtime.step(now)
    local seq = data().facts.host.cycle.seq or 0
    local slot = store()
    if seq ~= slot.activeCycle then
        cancelAll()
        slot.activeCycle = seq
        spawnCycle(seq, now)
        return true
    end
    if not control.isRunning(data()) then
        cancelAll()
        return false
    end

    local task = pickDue(now)
    if not task then return false end
    local ok = canRun(task)
    if not ok then
        remove(task.id)
        return true
    end

    local method = produce.method(task.level)
    if not method then
        fail(task, "制作方法未注册", nil, now)
        return true
    end

    local env = { chunkLimit = function() return chunkLimit(task) end }
    local response = machine.step(task, method, now, env,
        function(command) return executeCommand(task, command) end)
    local finishedAt = clock.uptime()
    task.lastStartedAt = now
    task.lastFinishedAt = finishedAt
    if response.status == "done" then
        task.completedAt = finishedAt
        complete(task, finishedAt)
    elseif response.status == "wait" then
        task.runAt = finishedAt + math.max(0.05, tonumber(response.seconds) or 0.05)
        task.expectedAt = task.runAt
    elseif response.status == "continue" then
        task.runAt = finishedAt + 0.05
        task.expectedAt = task.runAt
    else
        task.failedAt = finishedAt
        fail(task, response.reason, response.failure, finishedAt)
    end
    return true
end

return runtime