--------------------------------------------------------------------------------
-- PurifyWater/services/produce_service.lua
--
-- 定位：制作自动化绑定与侧位配置状态机。
-- 功能：扫描转运器、维护绑定与缺失对账、自动识别侧位和槽位、刷新速率并支撑启停判断。
-- 边界：是 produce 配置数据的唯一写者；具体制作流程由 produce_runtime 执行。
--------------------------------------------------------------------------------

local config = require("shared.config")
local constants = require("shared.constants")
local state = require("services.state")
local log = require("services.log")
local device = require("hardware.device")
local machines = require("hardware.machines")
local transposer = require("hardware.transposer")
local produce_store = require("services.produce_store")
local layout = require("business.produce.layout")
local produce_registry = require("business.produce")
local util = require("shared.util")

local service = {}
local INTERVAL = {
    scan = (config.PRODUCE and config.PRODUCE.SCAN) or 10,
}
local MISSING_SCANS = constants.PRODUCE_MISSING_SCANS or 3

local due = { scan = 0 }
---@type table|nil
local current = nil
local queue = {}
local queued = {}
local refreshRequested = false
local configBatches = {}

local function produce()
    return state.get().produce
end

local function machineLabel(level, address)
    for _, machine in ipairs(machines.of(level)) do
        if machine.address == address then
            if type(machine.x) == "number" and type(machine.y) == "number"
                and type(machine.z) == "number" then
                return string.format("(%d,%d,%d)", machine.x, machine.y, machine.z)
            end
            break
        end
    end
    return util.shortAddress(address)
end
local function findPosition(list, field, value)
    for index, entry in ipairs(list or {}) do
        if entry[field] == value then return index, entry end
    end
end

local function findActive(machine)
    local _, entry = findPosition(produce().bindings, "machine", machine)
    return entry
end

local function findCandidate(machine)
    local _, entry = findPosition(produce().candidates, "machine", machine)
    return entry
end

local function findAnyByMachine(machine)
    return findActive(machine) or findCandidate(machine)
end

local function findAnyByTransposer(address)
    local active = produce().bindings
    for _, entry in ipairs(active) do
        if entry.transposer == address then return entry end
    end
    local candidates = produce().candidates
    for _, entry in ipairs(candidates) do
        if entry.transposer == address then return entry end
    end
end

local function bindingLess(a, b)
    if a.level ~= b.level then return a.level < b.level end
    return tostring(a.machine) < tostring(b.machine)
end

--- 保存当前绑定和候选表，并记录写入失败。
local function persist()
    local ok, err = produce_store.save(produce().bindings, produce().candidates)
    if not ok then log.error("制作配置保存失败：" .. tostring(err)) end
    return ok == true
end

local function keyBusy(key)
    if key == nil then return false end
    if current and current.key == key then return true end
    for _, task in ipairs(queue) do
        if task.key == key then return true end
    end
    return queued[key] == true
end

--- 把组件任务加入串行队列；同一 key 不允许并发。
local function enqueue(task)
    if task.key and keyBusy(task.key) then return false end
    if task.key then queued[task.key] = true end
    queue[#queue + 1] = task
    return true
end

local function batchFor(level)
    local batch = configBatches[level]
    if not batch then
        batch = { side = 0, slot = 0 }
        configBatches[level] = batch
    end
    return batch
end

local function recordConfig(level, field)
    local batch = batchFor(level)
    batch[field] = (batch[field] or 0) + 1
end

local function hasConfigure(level)
    if current and current.kind == "configure" and current.entry and current.entry.level == level then
        return true
    end
    for _, task in ipairs(queue) do
        if task.kind == "configure" and task.entry and task.entry.level == level then return true end
    end
    return false
end

local function flushConfigBatch(level)
    if hasConfigure(level) then return end
    local batch = configBatches[level]
    configBatches[level] = nil
    if not batch or (batch.side == 0 and batch.slot == 0) then return end
    local parts = {}
    if batch.side > 0 then parts[#parts + 1] = string.format("侧位 %d 台", batch.side) end
    if batch.slot > 0 then parts[#parts + 1] = string.format("槽位 %d 台", batch.slot) end
    log.system(string.format("%s 配置完成：%s", constants.levelCode(level), table.concat(parts, "，")))
end

local function finishCurrent()
    local finished = current
    if finished and finished.key then queued[finished.key] = nil end
    current = nil
    if finished and finished.kind == "configure" and finished.entry then
        flushConfigBatch(finished.entry.level)
    end
end

--- 排队执行侧位/槽位配置，并合并同机器的重复请求。
local function queueConfigure(entry, mode)
    if not entry then return false end
    local key = "configure:" .. tostring(entry.machine)
    if current and current.key == key then
        if mode == "force" then current.mode = "force" end
        return false
    end
    for _, task in ipairs(queue) do
        if task.key == key then
            if mode == "force" then task.mode = "force" end
            return false
        end
    end
    return enqueue({ kind = "configure", key = key, entry = entry, mode = mode or "auto" })
end

local function machineExists(level, address)
    for _, machine in ipairs(machines.of(level)) do
        if machine.address == address then return machine end
    end
end

local function sortedTransposers(devices)
    local out = {}
    for address, kind in pairs(devices or {}) do
        if kind == "transposer" then out[#out + 1] = address end
    end
    table.sort(out)
    return out
end

local function bindingAddressBound(address)
    return findAnyByTransposer(address) ~= nil
end

--- 排队读取转运速率，并区分绑定、刷新和恢复场景。
local function queueRate(entry, mode)
    if not entry then return false end
    mode = mode or "restore"
    local key = "refresh-rate:" .. tostring(entry.transposer)
    if current and current.key == key then
        if mode == "refresh" then current.mode = "refresh" end
        return false
    end
    for _, task in ipairs(queue) do
        if task.key == key then
            if mode == "refresh" then task.mode = "refresh" end
            return false
        end
    end
    return enqueue({ kind = "rate", key = key, mode = mode, entry = entry })
end

--- 根据最新组件列表维护在线表、missing 计数和自动恢复。
local function reconcilePresence(devices)
    local data = produce()
    local oldOnline = data.online or {}
    local nextActive, nextCandidates = {}, {}
    local changed, onlineChanged = false, false

    for _, entry in ipairs(data.bindings or {}) do
        local online = devices[entry.transposer] == "transposer"
        if online then
            nextActive[#nextActive + 1] = entry
            if entry.miss ~= nil then
                entry.miss = nil
                changed = true
            end
            if not tonumber(entry.rate) then queueRate(entry, "restore") end
            if entry.sides == nil then
                queueConfigure(entry, "auto")
            elseif entry.slots == nil then
                queueConfigure(entry, "slots")
            elseif entry.forceOff == true then
                queueConfigure(entry, "diagnose")
            end
        else
            entry.miss = 1
            nextCandidates[#nextCandidates + 1] = entry
            changed = true
            log.warn(string.format("%s 转运器 %s 离线（1/%d，机器 %s）",
                constants.levelCode(entry.level), util.shortAddress(entry.transposer),
                MISSING_SCANS, machineLabel(entry.level, entry.machine)))
        end
    end

    for _, entry in ipairs(data.candidates or {}) do
        local online = devices[entry.transposer] == "transposer"
        if online then
            entry.miss = nil
            nextActive[#nextActive + 1] = entry
            changed = true
            log.system(string.format("%s 转运器 %s 恢复在线（机器 %s）",
                constants.levelCode(entry.level), util.shortAddress(entry.transposer),
                machineLabel(entry.level, entry.machine)))
            if not tonumber(entry.rate) then queueRate(entry, "restore") end
            if entry.sides == nil then
                queueConfigure(entry, "auto")
            elseif entry.slots == nil then
                queueConfigure(entry, "slots")
            elseif entry.forceOff == true then
                queueConfigure(entry, "diagnose")
            end
        else
            local miss = math.max(1, tonumber(entry.miss) or 1) + 1
            entry.miss = miss
            if miss >= MISSING_SCANS then
                changed = true
                log.warn(string.format("%s 转运器 %s 连续 %d 次缺失，已解除绑定（机器 %s）",
                    constants.levelCode(entry.level), util.shortAddress(entry.transposer),
                MISSING_SCANS, machineLabel(entry.level, entry.machine)))
            else
                nextCandidates[#nextCandidates + 1] = entry
                changed = true
            end
        end
    end

    table.sort(nextActive, bindingLess)
    table.sort(nextCandidates, bindingLess)
    data.bindings = nextActive
    data.candidates = nextCandidates

    local onlineMap = {}
    for _, entry in ipairs(nextActive) do onlineMap[entry.transposer] = true end
    for _, entry in ipairs(nextCandidates) do onlineMap[entry.transposer] = false end
    for address, value in pairs(onlineMap) do
        if oldOnline[address] ~= value then onlineChanged = true; break end
    end
    for address in pairs(oldOnline) do
        if onlineMap[address] == nil then onlineChanged = true; break end
    end
    data.online = onlineMap

    if changed then persist() end
    if changed or onlineChanged then state.bump() end
end

local function queueRefreshProperties()
    for _, entry in ipairs(produce().bindings) do
        if produce().online and produce().online[entry.transposer] == true then
            queueRate(entry, "refresh")
        end
    end
end

local function componentScan(now, force)
    local devices = device.list()
    reconcilePresence(devices)
    due.scan = now + INTERVAL.scan
    if force then queueRefreshProperties() end
end

local function startBindingRate(level, machine, address)
    return enqueue({
        kind = "rate",
        key = "bind-rate:" .. tostring(address),
        mode = "binding",
        level = level,
        machine = machine,
        transposer = address,
    })
end

--- 扫描未被占用的转运器，生成当前机器的候选列表。
local function stepCandidates(task)
    local item = produce().binding
    if not item or item.level ~= task.level or item.machine ~= task.machine then
        finishCurrent()
        return
    end

    local devices = device.list()
    local candidates = {}
    for _, address in ipairs(sortedTransposers(devices)) do
        if not bindingAddressBound(address) then candidates[#candidates + 1] = address end
    end
    item.candidates = candidates
    item.loading = false
    state.bump()
    finishCurrent()
end

--- 校验转运器唯一性，持久化绑定并启动侧位配置。
local function commitBinding(level, machine, address, rate)
    local other = findAnyByTransposer(address)
    if other and other.machine ~= machine then
        produce().binding = nil
        log.warn(string.format("%s 转运器 %s 已被机器 %s 占用，绑定失败",
            constants.levelCode(level), util.shortAddress(address), machineLabel(level, other.machine)))
        return false
    end

    local old = produce()
    local active, candidates = {}, {}
    for _, entry in ipairs(old.bindings or {}) do
        if entry.machine ~= machine and entry.transposer ~= address then active[#active + 1] = entry end
    end
    for _, entry in ipairs(old.candidates or {}) do
        if entry.machine ~= machine and entry.transposer ~= address then candidates[#candidates + 1] = entry end
    end
    local entry = {
        level = level,
        machine = machine,
        transposer = address,
        rate = rate,
    }
    active[#active + 1] = entry
    table.sort(active, bindingLess)
    table.sort(candidates, bindingLess)

    local ok = produce_store.save(active, candidates)
    if not ok then
        produce().binding = nil
        log.error(string.format("%s 绑定保存失败（机器 %s）",
            constants.levelCode(level), machineLabel(level, machine)))
        return false
    end

    old.bindings = active
    old.candidates = candidates
    old.online = old.online or {}
    old.online[address] = true
    old.binding = nil
    state.bump()
    log.system(string.format("%s 已绑定转运器 %s → 机器 %s（速率 %s/s）",
        constants.levelCode(level), util.shortAddress(address), machineLabel(level, machine),
        util.formatNumber(rate) .. "L"))
    queueConfigure(entry, "auto")
    return true
end

local function cacheItemSlots(level)
    return level ~= constants.T6_LEVEL
end

--- 根据当前六面数据重建槽位缓存并检查原料是否充足。
local function refreshSlots(entry, faces)
    local fluids, items = layout.requirements(entry.level)
    if not fluids then
        entry.slots = { ready = false, fluid = {}, item = {} }
        entry.forceOff = true
        entry.forceReason = "该等级没有制作自动化侧位定义"
        return false, entry.forceReason
    end
    local cacheItems = cacheItemSlots(entry.level)
    local slots = layout.buildSlots(faces, entry.sides, items, cacheItems)
    -- T6 仅在可用性扫描中使用目标侧补足物品，不改已落盘的侧位角色。
    local availabilitySides = entry.sides
    if not cacheItems then
        local itemSources, seen = {}, {}
        local target = entry.sides.itemTarget
        if target ~= nil then
            itemSources[#itemSources + 1] = target
            seen[target] = true
        end
        for _, side in ipairs(entry.sides.itemSources or {}) do
            if not seen[side] then
                itemSources[#itemSources + 1] = side
                seen[side] = true
            end
        end
        availabilitySides = {
            sources = entry.sides.sources,
            itemSources = itemSources,
        }
    end
    local available, missing = layout.sourcesAvailable(
        faces, availabilitySides, fluids, items)
    if not cacheItems and #(entry.sides.itemSources or {}) == 0 then
        available = false
        missing = "没有物品来源侧"
    end
    slots.ready = available == true
    entry.slots = slots
    if available then
        entry.forceOff = false
        entry.forceReason = nil
    else
        entry.forceOff = true
        entry.forceReason = "原料不足：" .. tostring(missing or "未知原料")
    end
    return available, missing
end

--- 根据任务模式分类侧位或仅刷新槽位，并在成功后持久化。
local function applyConfig(task)
    local entry = task.entry
    if findActive(entry.machine) ~= entry then return end

    local fluids, items = layout.requirements(entry.level)
    if not fluids then
        entry.sideFail = "该等级没有制作自动化侧位定义"
        state.bump()
        return
    end

    local topology = layout.topology(task.faces)
    if task.mode == "slots" then
        if not entry.sides then
            entry.sideFail = "侧位尚未配置"
            entry.slots = { ready = false, fluid = {}, item = {} }
            state.bump()
            return
        end
        local ok, missing = refreshSlots(entry, task.faces)
        entry.topology = topology
        entry.sideFail = nil
        state.bump()
        if ok then
            recordConfig(entry.level, "slot")
        else
            log.warn(string.format("%s 槽位配置失败：%s（机器 %s）",
                constants.levelCode(entry.level), tostring(entry.forceReason or missing), machineLabel(entry.level, entry.machine)))
        end
        return
    end

    if task.mode == "diagnose" then
        if entry.topology ~= nil and entry.topology == topology then
            local ok, missing = refreshSlots(entry, task.faces)
            entry.sideFail = nil
            state.bump()
            if not ok then
                log.warn(string.format("%s 槽位检查失败：%s（机器 %s）",
                    constants.levelCode(entry.level), tostring(entry.forceReason or missing), machineLabel(entry.level, entry.machine)))
            end
            return
        end
        entry.configChanged = true
    elseif task.mode ~= "force" then
        if entry.sides ~= nil and entry.configChanged ~= true then return end
    end

    local sides, reason = layout.classify(task.faces, fluids, items)
    if not sides then
        entry.sideFail = reason
        entry.configured = false
        entry.slots = { ready = false, fluid = {}, item = {} }
        entry.forceOff = true
        entry.forceReason = tostring(reason)
        state.bump()
        log.warn(string.format("%s 侧位配置失败：%s（机器 %s）",
            constants.levelCode(entry.level), tostring(reason), machineLabel(entry.level, entry.machine)))
        return
    end

    local oldSides, oldTopology = entry.sides, entry.topology
    local oldFail = entry.sideFail
    local oldConfigured = entry.configured
    local oldChanged = entry.configChanged
    entry.sides = sides
    entry.topology = topology
    entry.sideFail = nil
    entry.configured = true
    entry.configChanged = false

    if not persist() then
        entry.sides, entry.topology = oldSides, oldTopology
        entry.sideFail = oldFail
        entry.configured = oldConfigured
        entry.configChanged = oldChanged
        return
    end

    recordConfig(entry.level, "side")
    local slotsOk, slotsMissing = refreshSlots(entry, task.faces)
    if slotsOk then
        recordConfig(entry.level, "slot")
    else
        log.warn(string.format("%s 槽位配置失败：%s（机器 %s）",
            constants.levelCode(entry.level), tostring(entry.forceReason or slotsMissing), machineLabel(entry.level, entry.machine)))
    end
    state.bump()
end
--- 逐面读取流体罐和物品槽，保证每次只执行一个组件调用。
local function advanceConfig(task)
    local entry = task.entry
    if not entry or findActive(entry.machine) ~= entry then
        finishCurrent()
        return
    end

    local flu, items = layout.requirements(entry.level)
    if not flu then
        applyConfig(task)
        finishCurrent()
        return
    end

    task.faces = task.faces or {}
    task.side = task.side or 0
    task.phase = task.phase or "fluid"
    local needItems = items ~= nil and #items > 0

    while true do
        if task.side > 5 then
            applyConfig(task)
            finishCurrent()
            return
        end

        local face = task.faces[task.side] or {}
        task.faces[task.side] = face
        if task.phase == "fluid" then
            face.fluids, face.fluidErr = transposer.containers(entry.transposer, task.side)
            task.phase = needItems and "item" or "next"
            return
        elseif task.phase == "item" then
            face.items, face.itemErr = transposer.items(entry.transposer, task.side)
            task.phase = "next"
            return
        else
            task.side = task.side + 1
            task.phase = "fluid"
        end
    end
end

--- 读取并校验转运速率，完成绑定提交、刷新或恢复流程。
local function stepRate(task)
    local rate, err
    if task.mode == "binding" then
        local item = produce().binding
        if task.cancelled or not item or item.machine ~= task.machine then
            finishCurrent()
            return
        end
        rate, err = transposer.rate(task.transposer)
        local minRate = produce_registry.minTransferRate(task.level)
        if type(rate) ~= "number" or rate <= 0 then
            item.loading = false
            state.bump()
            log.warn(string.format("%s 转运器 %s 速率未知，绑定失败：%s",
                constants.levelCode(task.level), util.shortAddress(task.transposer),
                tostring(err or "速率无效")))
            finishCurrent()
            return
        elseif minRate and rate < minRate then
            item.loading = false
            state.bump()
            log.warn(string.format("%s 转运器 %s 速率不足：%s/s < %s/s，绑定失败",
                constants.levelCode(task.level), util.shortAddress(task.transposer),
                util.formatNumber(rate) .. "L", util.formatNumber(minRate) .. "L"))
            finishCurrent()
            return
        end
        commitBinding(task.level, task.machine, task.transposer, rate)
        finishCurrent()
        return
    end

    local entry = task.entry
    if not entry or findActive(entry.machine) ~= entry then
        finishCurrent()
        return
    end
    rate, err = transposer.rate(entry.transposer)
    if type(rate) == "number" and rate > 0 then
        local rateChanged = entry.rate ~= rate
        local hadError = entry.rateErr ~= nil
        entry.rate = rate
        entry.rateErr = nil
        if rateChanged then persist() end
        if rateChanged or hadError then state.bump() end
    else
        local text = tostring(err or "速率无效")
        if entry.rateErr ~= text then
            entry.rateErr = text
            state.bump()
        end
        log.warn(string.format("%s 刷新转运速率失败 %s：%s",
            constants.levelCode(entry.level), util.shortAddress(entry.transposer), text))
    end
    if task.mode ~= "restore" then queueConfigure(entry, "force") end
    finishCurrent()
end

--- 分派当前制作配置队列任务。
local function runCurrent(task)
    if task.kind == "rate" then
        stepRate(task)
    elseif task.kind == "candidates" then
        stepCandidates(task)
    elseif task.kind == "configure" then
        advanceConfig(task)
    else
        finishCurrent()
    end
    return false
end
--- 从 data/produce.txt 恢复绑定与候选表。
function service.load()
    local active, candidates, problems = produce_store.load()
    local data = produce()
    data.bindings = active
    data.candidates = candidates
    data.online = nil
    data.binding = nil
    for _, problem in ipairs(problems or {}) do log.warn("制作配置读取异常：" .. tostring(problem)) end
    due.scan = 0
    state.bump()
end

--- 请求立即重新扫描转运器并刷新属性。
function service.requestRefresh()
    refreshRequested = true
    due.scan = 0
end

--- 返回制作配置状态机下一次需要推进的时间。
function service.nextDue(now)
    if current or #queue > 0 or refreshRequested then return now end
    return due.scan
end

--- 至多执行一个制作配置或组件对账任务。
function service.step(now)
    if current then return runCurrent(current) end
    if #queue > 0 then
        current = table.remove(queue, 1)
        return runCurrent(current)
    end
    if refreshRequested then
        refreshRequested = false
        componentScan(now, true)
        return false
    end
    if due.scan <= now then
        componentScan(now, false)
        return false
    end
    return false
end

--- 开始为指定等级机器选择未绑定转运器。
function service.beginBind(level, machine)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if not layout.implemented(level) then
        return false, constants.levelCode(level) .. " 制作自动化尚未实现"
    end
    if type(machine) ~= "string" or machine == "" then return false, "机器无效" end
    if produce().binding then return false, "已有正在进行的绑定，请先取消" end
    if not machineExists(level, machine) then
        return false, "机器不在该级注册表（先刷新扫描再试）"
    end

    produce().binding = {
        level = level,
        machine = machine,
        loading = true,
        candidates = {},
    }
    state.bump()
    enqueue({
        kind = "candidates",
        key = "candidates:" .. level .. ":" .. machine,
        level = level,
        machine = machine,
    })
    log.system(string.format("%s 开始选择转运器（机器 %s）",
        constants.levelCode(level), machineLabel(level, machine)))
    return true, nil
end

--- 取消正在进行的转运器绑定选择。
function service.cancelBind()
    if not produce().binding then return true, nil end

    produce().binding = nil
    if current and (current.mode == "binding" or current.kind == "candidates") then
        current.cancelled = true
    end
    for index = #queue, 1, -1 do
        local task = queue[index]
        if task.mode == "binding" or task.kind == "candidates" then
            if task.key then queued[task.key] = nil end
            table.remove(queue, index)
        end
    end
    state.bump()
    log.system("已取消绑定选择")
    return true, nil
end

--- 确认选中转运器，或选择空值解除现有绑定。
function service.selectBindCandidate(machine, address)
    local item = produce().binding
    if not item or item.machine ~= machine then return false, "绑定选择已失效，请重新打开" end

    address = tostring(address or "")
    if address == "" then
        if findAnyByMachine(machine) then
            local ok, err = service.unbind(machine)
            if not ok then return false, err end
        else
            produce().binding = nil
            state.bump()
        end
        return true, nil
    end

    if item.loading then return false, "正在扫描未绑定转运器" end
    local allowed = false
    for _, candidate in ipairs(item.candidates or {}) do
        if candidate == address then allowed = true; break end
    end
    if not allowed then return false, "该转运器已不在待选列表，请重新选择" end
    if bindingAddressBound(address) then return false, "该转运器已被其他机器绑定" end

    item.loading = true
    state.bump()
    if not startBindingRate(item.level, item.machine, address) then
        item.loading = false
        state.bump()
        return false, "绑定时序冲突，请重试"
    end
    return true, nil
end

--- 检查等级制作就绪状态。
--- 返回 `ready`、`pending`、`error` 或 `invalid`，并附带可展示原因。
---@param level number|string 等级。
---@return string status 就绪状态。
---@return string|nil reason 非 ready 状态的原因。
function service.canEnable(level)
    local levelNumber = tonumber(level)
    if not levelNumber or not layout.implemented(levelNumber) then
        return "invalid", constants.levelCode(levelNumber or 0) .. " 制作自动化尚未实现"
    end

    local snapshot = state.get()
    if snapshot.facts.hardware.value == nil then
        return "pending", "硬件状态尚未建立"
    end

    local online = produce().online
    if online == nil then
        return "pending", "转运器在线状态尚未建立"
    end

    local list = machines.of(levelNumber)
    if #list == 0 then return "invalid", constants.levelCode(levelNumber) .. " 没有已部署机器" end

    local unbound, missing, offline = 0, 0, 0
    local invalidConfig, materialBlocked = 0, 0
    local pendingConfig, ratePending, rateErrors = 0, 0, 0
    local rateError

    for _, machine in ipairs(list) do
        local entry = findAnyByMachine(machine.address)
        if not entry then
            unbound = unbound + 1
        else
            if entry.miss then missing = missing + 1 end
            if online[entry.transposer] ~= true then offline = offline + 1 end

            if entry.sideFail then
                invalidConfig = invalidConfig + 1
            elseif entry.sides == nil or entry.slots == nil then
                pendingConfig = pendingConfig + 1
            elseif entry.slots.ready ~= true then
                invalidConfig = invalidConfig + 1
            elseif entry.forceOff == true then
                materialBlocked = materialBlocked + 1
            end

            local rate = tonumber(entry.rate)
            if not rate or rate <= 0 then
                if entry.rateErr then
                    rateErrors = rateErrors + 1
                    rateError = rateError or tostring(entry.rateErr)
                else
                    ratePending = ratePending + 1
                end
            end
        end
    end

    if unbound > 0 then return "invalid", string.format("还有 %d 台机器未绑定转运器", unbound) end
    if missing > 0 then return "invalid", string.format("有 %d 台转运器缺失", missing) end
    if offline > 0 then return "invalid", string.format("有 %d 台转运器离线", offline) end
    if invalidConfig > 0 then
        return "invalid", string.format("有 %d 台机器侧位或槽位未就绪", invalidConfig)
    end
    if materialBlocked > 0 then
        return "invalid", string.format("有 %d 台机器原料不足", materialBlocked)
    end
    if rateErrors > 0 then
        return "error", string.format("有 %d 台机器转运速率读取失败：%s", rateErrors, tostring(rateError))
    end
    if pendingConfig > 0 or ratePending > 0 then
        if pendingConfig > 0 then
            return "pending", string.format("有 %d 台机器正在建立侧位或槽位", pendingConfig)
        end
        return "pending", string.format("有 %d 台机器转运速率尚未读取", ratePending)
    end
    return "ready"
end

--- 解除机器绑定并同步停用对应制作自动化。
function service.unbind(machine)
    if type(machine) ~= "string" then return false, "机器无效" end
    local active, candidates = {}, {}
    ---@type table|nil
    local removed, removedAddress, removedLevel
    for _, entry in ipairs(produce().bindings or {}) do
        if entry.machine == machine then
            removed, removedAddress, removedLevel = entry, entry.transposer, entry.level
        else
            active[#active + 1] = entry
        end
    end
    for _, entry in ipairs(produce().candidates or {}) do
        if entry.machine == machine then
            removed = removed or entry
            removedAddress = removedAddress or entry.transposer
            removedLevel = removedLevel or entry.level
        else
            candidates[#candidates + 1] = entry
        end
    end
    if not removed then return false, "该机器未绑定" end
    local product = state.get().produce.levels[removedLevel]
    if product and product.enabled == true then
        local ok, err = require("services.config_service").setProduceEnabled(removedLevel, false)
        if not ok then return false, err end
    end

    local ok = produce_store.save(active, candidates)
    if not ok then return false, "写绑定表失败（data/produce.txt）" end
    produce().bindings = active
    produce().candidates = candidates
    if produce().online then produce().online[removedAddress] = nil end
    if produce().binding and produce().binding["machine"] == machine then produce().binding = nil end
    if current and current["entry"] and current["entry"]["machine"] == machine then current.cancelled = true end
    state.bump()
    log.system(string.format("%s 已解除绑定 %s（机器 %s）",
        constants.levelCode(removedLevel), util.shortAddress(removedAddress), machineLabel(removedLevel, machine)))
    return true, nil
end

--- 根据转运失败类型决定保留侧位还是重新诊断。
function service.onTransferFailure(machine, failure)
    local entry = findActive(machine)
    if not entry then return false, "该机器未绑定转运器" end
    if failure and failure.code == "ENERGY" then
        log.warn(string.format("%s 转运能量不足，保留侧位（机器 %s）",
            constants.levelCode(entry.level), machineLabel(entry.level, entry.machine)))
        return false, "energy"
    end
    entry.lastFailure = failure
    queueConfigure(entry, "diagnose")
    return true, nil
end

--- 处理制作绑定、取消、选择和解除命令。
function service.handle(name, action)
    action = action or {}
    if name == "produce_bind_begin" then
        return true, service.beginBind(action.level, action.machine)
    elseif name == "produce_bind_cancel" then
        return true, service.cancelBind()
    elseif name == "produce_bind_select" then
        return true, service.selectBindCandidate(action.machine, action.address)
    elseif name == "produce_unbind" then
        return true, service.unbind(action.machine)
    end
    return false
end

return service
