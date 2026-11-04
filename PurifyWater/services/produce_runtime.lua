--------------------------------------------------------------------------------
-- PurifyWater/services/produce_runtime.lua
--
-- 定位：制作任务的运行时执行器。
-- 功能：按周期生成任务，校验安全条件，单步推进状态机，并把命令映射为硬件读写。
-- 边界：每个步骤最多一次组件调用；不定义具体等级配方，不写绑定配置；失效时通过 config_service 撤销自动化。
--------------------------------------------------------------------------------

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
local config_service = require("services.config_service")

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

--- 返回机器运行状态：ready 时第二值为 boolean，pending/error 时为原因。
local function machineStatus(address)
    local fact = data().facts.machines[address]
    if not fact then return "pending", "机器状态尚未建立" end
    if fact.active ~= nil then return "ready", fact.active end
    if fact.activeErr then return "error", tostring(fact.activeErr) end
    return "pending", "机器运行状态尚未建立"
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

--- 根据绑定转运速率计算单次转运量上限。
local function chunkLimit(task)
    local rate = tonumber(task.entry.rate) or 0
    return math.max(1, math.floor(rate * (CONFIG.PRODUCE.CHUNK_RATIO or 0.05)))
end

--- 同步执行一条状态机命令，并规范化为事件结果。
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

--- 在命令执行前后记录耗时和最近结果。
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
--- 检查不涉及配置就绪的任务生命周期条件。
local function taskStillValid(task)
    if task.cycleSeq ~= data().facts.host.cycle.seq then return false, "周期已变化" end
    if not entryActive(task.entry) then return false, "绑定已失效" end
    local product = data().produce.levels[task.level] or {}
    if product.enabled ~= true then return false, "制作自动化未启用" end

    local activeStatus, activeValue = machineStatus(task.machine)
    if activeStatus == "pending" then
        return false, "机器运行状态尚未建立", "pending"
    elseif activeStatus == "error" then
        return false, "机器运行状态读取失败：" .. tostring(activeValue), "error"
    elseif activeValue ~= true then
        return false, "机器未运行", "inactive"
    end
    return true
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
        local amount = util.formatNumber(item.amount or 0)
        if item.unit == "fluid" then
            parts[#parts + 1] = item.label .. " " .. amount .. "L"
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

--- 按等级优先级和到期时间选择下一个任务。
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

--- 取消指定等级的全部制作任务，用于自动关闭该等级自动化。
local function cancelLevelTasks(level)
    for id, task in pairs(store().tasks or {}) do
        if task.level == level then remove(id) end
    end
end

--- 自动撤销等级自动化；reason 同时作为用户可见日志。
local function disableLevel(level, status, reason)
    local product = data().produce.levels[level]
    if not product or product.enabled ~= true then return false end

    cancelLevelTasks(level)
    local severity = status == "error" and "error" or "warn"
    local ok, err = config_service.setProduceEnabled(level, false, reason, severity)
    if not ok then
        product.enabled = false
        state.bump()
        log.error(string.format("%s 制作自动化自动关闭失败：%s；原因：%s",
            constants.levelCode(level), tostring(err), tostring(reason)))
        return false
    end
    return true
end

--- 在新主机周期为所有就绪且已启用的绑定创建制作任务。
local function spawnCycle(seq, now)
    if seq <= 0 or not control.isRunning(data()) then return end
    local progress = tonumber(data().facts.host.progress.value)
    local maxProgress = tonumber(data().facts.host.progressMax.value)
    if progress and maxProgress and maxProgress > 0
        and progress / maxProgress > (CONFIG.PRODUCE.CYCLE_CUTOFF or 0.9) then
        return
    end
    local ready = {}
    for level = 1, constants.LEVEL_COUNT do
        local product = data().produce.levels[level] or {}
        if product.enabled == true then
            local status, reason = produce_service.canEnable(level)
            ready[level] = status == "ready"
            if status ~= "ready" and status ~= "pending" then
                disableLevel(level, status, reason)
            end
        end
    end

    for _, entry in ipairs(data().produce.bindings or {}) do
        local method = produce.method(entry.level)
        local product = data().produce.levels[entry.level] or {}
        if ready[entry.level] and product.enabled == true and method then
            local activeStatus, activeValue = machineStatus(entry.machine)
            if activeStatus == "ready" then
                if activeValue == true then addTask(entry, method, seq, now) end
            elseif activeStatus == "error" then
                disableLevel(entry.level, "error",
                    "机器运行状态读取失败：" .. tostring(activeValue))
            end
        end
    end
end

--- 清空临时制作任务并同步当前主机周期。
function runtime.load()
    store().tasks = {}
    store().activeCycle = data().facts.host.cycle.seq or 0
end

--- 返回制作任务或周期切换的下一次处理时间。
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

--- 至多推进一个制作任务步骤，或响应周期切换。
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
    local taskValid, taskReason, taskFailure = taskStillValid(task)
    if not taskValid then
        remove(task.id)
        if taskFailure == "error" then disableLevel(task.level, "error", taskReason) end
        return true
    end

    local status, reason = produce_service.canEnable(task.level)
    if status == "pending" then
        remove(task.id)
        return true
    elseif status ~= "ready" then
        remove(task.id)
        disableLevel(task.level, status, reason)
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
