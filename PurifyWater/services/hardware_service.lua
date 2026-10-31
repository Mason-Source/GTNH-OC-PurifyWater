-- 设备扫描与观测状态机：每个步骤最多一个组件调用，完成后统一发布事实。
local clock = require("services.clock")
local constants = require("shared.constants")
local config = require("shared.config")
local state = require("services.state")
local log = require("services.log")
local device = require("hardware.device")
local machines = require("hardware.machines")
local probes = require("hardware.probes")
local energy = require("hardware.energy")
local fluid = require("hardware.fluid")
local host_cycle = require("services.host_cycle")
local hardware_store = require("services.hardware_store")
local learning_service = require("services.learning_service")

local service = {}
local due = {
    scan = 0,
    energy = 0,
    hostSwitch = 0,
    hostProgress = 0,
    plantSwitch = 0,
    plantSample = 0,
    active = math.huge,
    water = math.huge,
}
local scanState = nil
local hostProgressState = nil
local plantSwitchState = nil
local plantSampleState = nil
local activeState = nil
local activeRequested = true
local forceRefresh = false

local INTERVAL = {
    scan = config.INTERVAL.HARDWARE or 10,
    energy = config.INTERVAL.HARDWARE or 10,
    hostSwitch = config.INTERVAL.HARDWARE or 10,
    hostProgress = config.INTERVAL.HOST_PROGRESS or 3,
    plantSwitch = config.INTERVAL.HARDWARE or 10,
    plantSample = config.INTERVAL.HARDWARE or 10,
    water = config.INTERVAL.WATER or 5,
}

local function factOf(address)
    local facts = state.get().facts.machines
    local fact = facts[address]
    if not fact then
        fact = { address = address }
        facts[address] = fact
    end
    return fact
end

local function rebuildLevels()
    local data = state.get()
    for level = 1, constants.LEVEL_COUNT do
        local entries = machines.of(level)
        local aggregate = {
            deployed = 0,
            active = 0,
            switch = nil,
            parallel = nil,
            success = nil,
            on = 0,
            off = 0,
            unknown = 0,
            switchObservedAt = nil,
        }
        for _, machine in ipairs(entries) do
            aggregate.deployed = aggregate.deployed + 1
            local fact = factOf(machine.address)
            if fact.switch == true then aggregate.on = aggregate.on + 1
            elseif fact.switch == false then aggregate.off = aggregate.off + 1
            else aggregate.unknown = aggregate.unknown + 1 end
            if fact.active == true then aggregate.active = aggregate.active + 1 end
            local observedAt = tonumber(fact.switchObservedAt)
            if observedAt and (aggregate.switchObservedAt == nil or observedAt < aggregate.switchObservedAt) then
                aggregate.switchObservedAt = observedAt
            end
            if type(fact.parallel) == "number"
                and (aggregate.parallel == nil or fact.parallel < aggregate.parallel) then
                aggregate.parallel = fact.parallel
            end
            if type(fact.success) == "number"
                and (aggregate.success == nil or fact.success < aggregate.success) then
                aggregate.success = fact.success
            end
        end
        if aggregate.on > 0 and aggregate.off == 0 and aggregate.unknown == 0 then
            aggregate.switch = true
        elseif aggregate.off > 0 and aggregate.on == 0 and aggregate.unknown == 0 then
            aggregate.switch = false
        else
            aggregate.switch = nil
        end
        data.facts.levels[level] = aggregate
    end
end

local function publishRegistry(devices)
    local data = state.get()
    local summary = machines.summary()
    local list = {}
    local me = false
    for address, kind in pairs(devices or {}) do
        list[#list + 1] = { address = address, kind = kind }
        if kind == "fluid_interface" or kind == "me_interface" then me = true end
    end
    data.facts.hardware.value = list
    data.facts.hardware.summary = summary
    data.facts.hardware.me = me
    data.facts.hardware.observedAt = clock.uptime()

    local missing = {}
    if summary.host == 0 then missing[#missing + 1] = "净水厂主机" end
    if not me then missing[#missing + 1] = "ME网络接口" end
    if not summary.energy then missing[#missing + 1] = "能量仓" end
    data.facts.hardware.missing = missing

    rebuildLevels()
    state.bump()
end

local function finishScan(now, devices)
    local lines = machines.topologyLines()
    local changed = machines.consumeChanged()
    local ok, err = hardware_store.saveLines(lines)
    if not ok then log.error("硬件登记保存失败：" .. tostring(err)) end
    if changed then log.diag("硬件登记已更新") end
    publishRegistry(devices)
    scanState = nil
    if forceRefresh then activeRequested = true end
    forceRefresh = false
    due.scan = now + INTERVAL.scan
    due.energy = now
    due.hostSwitch = now
    due.plantSwitch = now
    due.plantSample = now
    due.water = now
    if activeRequested then due.active = now end
    return false
end

local function wantsCoordinates(level)
    return type(level) == "number" and level >= 1 and level <= constants.LEVEL_COUNT
end

local function completeScanTask(scanStateArg)
    scanStateArg.pending = nil
    scanStateArg.index = scanStateArg.index + 1
    return scanStateArg.index <= #scanStateArg.candidates
end

local function stepScan(now)
    if not scanState then
        local devices = device.list()
        local candidates, removed = machines.prepareScan(devices)
        local tasks = {}

        if forceRefresh then
            local addresses = {}
            for address, kind in pairs(devices) do
                if kind == "gt_machine" then addresses[#addresses + 1] = address end
            end
            table.sort(addresses)
            for _, address in ipairs(addresses) do
                tasks[#tasks + 1] = { address = address, phase = "name", force = true }
            end
        else
            table.sort(candidates)
            for _, address in ipairs(candidates) do
                tasks[#tasks + 1] = { address = address, phase = "name", force = false }
            end
            local needCoordinates = machines.needsCoordinates()
            table.sort(needCoordinates)
            for _, address in ipairs(needCoordinates) do
                tasks[#tasks + 1] = { address = address, phase = "coords", force = false }
            end
        end

        scanState = {
            devices = devices,
            candidates = tasks,
            removed = removed,
            index = 1,
            pending = nil,
        }
        if #tasks == 0 then return finishScan(now, devices) end
        return true
    end

    local task = scanState.pending
    if not task then
        task = scanState.candidates[scanState.index]
        if not task then return finishScan(now, scanState.devices) end
        scanState.pending = task
    end

    if task.phase == "name" then
        local name = device.name(task.address)
        if name then
            local entry
            if machines.isRegistered(task.address) then
                entry = machines.update(task.address, name)
            else
                entry = machines.add(task.address, name)
            end
            if entry and wantsCoordinates(entry.level) then
                task.phase = "coords"
                return true
            end
        end
        return completeScanTask(scanState)
    end

    local x, y, z = device.coordinates(task.address)
    if x ~= nil and y ~= nil and z ~= nil then
        machines.update(task.address, nil, x, y, z)
    end
    return completeScanTask(scanState)
end
local function stepEnergy(now)
    local hatch = machines.energy()
    local power = 0
    if hatch then
        local stored = device.invoke(hatch.address, "getEUMaxStored")
        power = energy.powerOf(hatch, type(stored) == "number" and stored or nil)
    end
    local data = state.get()
    local before = data.power.max
    data.power.max = power
    data.power.available = math.floor(power * (data.settings.energyFactor or 100) / 100)
    data.power.observedAt = clock.uptime()
    if before ~= power then state.bump() end
    due.energy = now + INTERVAL.energy
    return false
end

local function stepWater(now)
    local levels, err = fluid.readAll(state.get().facts.hardware.value or {})
    if levels then
        state.get().facts.water.value = levels
        state.get().facts.water.observedAt = clock.uptime()
        state.bump()
    elseif err then
        log.warn("水位读取失败：" .. tostring(err))
    end
    due.water = now + INTERVAL.water
    return false
end

local function stepHostSwitch(now)
    local host = machines.of(constants.HOST_LEVEL)[1]
    local fact = state.get().facts.host.switch
    if host then
        local value = probes.switch(host.address)
        if value ~= nil then
            fact.value = value
            fact.observedAt = clock.uptime()
            state.bump()
        end
    else
        fact.value = nil
        fact.observedAt = clock.uptime()
    end
    due.hostSwitch = now + INTERVAL.hostSwitch
    return false
end

local function stepHostProgress(now)
    local host = machines.of(constants.HOST_LEVEL)[1]
    if not host then
        hostProgressState = nil
        due.hostProgress = now + INTERVAL.hostProgress
        return false
    end

    if not hostProgressState then
        local value = probes.progress(host.address)
        if value == nil then
            due.hostProgress = now + INTERVAL.hostProgress
            return false
        end
        hostProgressState = { progress = value }
        return true
    end

    local maxProgress = probes.progressMax(host.address)
    local started = host_cycle.observe(hostProgressState.progress, maxProgress)
    hostProgressState = nil
    state.bump()
    if started then
        activeRequested = true
        due.active = now
    end
    due.hostProgress = now + INTERVAL.hostProgress
    return false
end

local function newPlantScan()
    return { level = 1, index = 1 }
end

local function nextMachine(scan)
    while scan.level <= constants.LEVEL_COUNT do
        local list = machines.of(scan.level)
        if scan.index <= #list then
            local machine = list[scan.index]
            scan.index = scan.index + 1
            return machine, scan.level
        end
        scan.level = scan.level + 1
        scan.index = 1
    end
end

local function stepPlantSwitch(now)
    plantSwitchState = plantSwitchState or newPlantScan()
    local machine, level = nextMachine(plantSwitchState)
    if not machine then
        plantSwitchState = nil
        rebuildLevels()
        state.bump()
        due.plantSwitch = now + INTERVAL.plantSwitch
        return false
    end
    local fact = factOf(machine.address)
    fact.level = level
    local previous = fact.switch
    local value = probes.switch(machine.address)
    fact.switch = value
    fact.switchObservedAt = clock.uptime()
    if previous ~= nil and value ~= nil and previous ~= value then
        learning_service.clearLevel(level)
    end
    return true
end

local function stepPlantSample(now)
    plantSampleState = plantSampleState or newPlantScan()
    if plantSampleState.sampleSeq == nil then plantSampleState.sampleSeq = host_cycle.seq() end
    local machine, level = nextMachine(plantSampleState)
    if not machine then
        plantSampleState = nil
        rebuildLevels()
        state.bump()
        due.plantSample = now + INTERVAL.plantSample
        return false
    end

    local fact = factOf(machine.address)
    fact.level = level
    if fact.active == true then
        local info = probes.sensor(machine.address)
        if info then
            fact.parallel = info.parallel
            fact.success = info.success
            fact.sampleObservedAt = clock.uptime()
            local seq = host_cycle.seq()
            if fact.active == true and seq > 0 and seq == plantSampleState.sampleSeq
                and fact.learnedCycle ~= seq then
                fact.learnedCycle = seq
                learning_service.observe(level, machine.address, info.parallel, info.success, seq)
            end
        end
    end
    return true
end

local function stepActive()
    if not activeRequested then
        due.active = math.huge
        return false
    end
    activeState = activeState or newPlantScan()
    local machine, level = nextMachine(activeState)
    if not machine then
        activeState = nil
        activeRequested = false
        rebuildLevels()
        state.bump()
        due.active = math.huge
        return false
    end
    local fact = factOf(machine.address)
    fact.level = level
    fact.active = probes.active(machine.address)
    fact.activeObservedAt = clock.uptime()
    return true
end

local PENDING = {
    { key = "scan", state = function() return scanState end, run = stepScan },
    { key = "active", state = function() return activeState end, run = function() return stepActive() end },
    { key = "plantSwitch", state = function() return plantSwitchState end, run = stepPlantSwitch },
    { key = "plantSample", state = function() return plantSampleState end, run = stepPlantSample },
    { key = "hostProgress", state = function() return hostProgressState end, run = stepHostProgress },
}

function service.nextDue(now)
    for _, item in ipairs(PENDING) do
        if item.state() then return now end
    end
    local best = math.huge
    for _, value in pairs(due) do
        if value < best then best = value end
    end
    return best
end

function service.step(now)
    for _, item in ipairs(PENDING) do
        if item.state() then return item.run(now) end
    end

    local order = { "scan", "active", "plantSwitch", "plantSample", "hostProgress", "hostSwitch", "energy", "water" }
    for _, key in ipairs(order) do
        if due[key] <= now then
            if key == "scan" then return stepScan(now) end
            if key == "active" then return stepActive() end
            if key == "plantSwitch" then return stepPlantSwitch(now) end
            if key == "plantSample" then return stepPlantSample(now) end
            if key == "hostProgress" then return stepHostProgress(now) end
            if key == "hostSwitch" then return stepHostSwitch(now) end
            if key == "energy" then return stepEnergy(now) end
            if key == "water" then return stepWater(now) end
        end
    end
    return false
end

function service.requestRefresh()
    scanState = nil
    forceRefresh = true
    due.scan = 0
end

function service.load()
    machines.load(hardware_store.loadLines())
    machines.consumeChanged()
    rebuildLevels()
end

return service
