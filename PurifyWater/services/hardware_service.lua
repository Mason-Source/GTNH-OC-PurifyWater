--------------------------------------------------------------------------------
-- PurifyWater/services/hardware_service.lua
--
-- 定位：硬件扫描与观测状态机。
-- 功能：逐步骤完成组件发现、机器登记、能源、水位、主机和 T1-T8 状态采集，并统一发布成功值或错误。
-- 边界：每个服务步骤最多一次组件调用；保留旧值供上层降级使用，不生成控制计划或修改用户配置。
--------------------------------------------------------------------------------

local clock = require("services.clock")
local constants = require("shared.constants")
local config = require("shared.config")
local state = require("services.state")
local facts = require("services.facts")
local log = require("services.log")
local device = require("hardware.device")
local machines = require("hardware.machines")
local probes = require("hardware.probes")
local energy = require("hardware.energy")
local fluid = require("hardware.fluid")
local host_cycle = require("services.host_cycle")
local hardware_store = require("services.hardware_store")
local learning_service = require("services.learning_service")
local util = require("shared.util")

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

--- 取得机器事实槽；switch/active/sample 的旧值保留，*Err 只记录最近一次读取失败。
local function factOf(address)
    local machineFacts = state.get().facts.machines
    local fact = machineFacts[address]
    if not fact then
        fact = { address = address }
        machineFacts[address] = fact
    end
    return fact
end

--- 把单机事实聚合为等级级开关、活跃数、并行和成功率。
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

--- 发布组件清单、机器摘要和缺失项，并推进 revision。
local function publishRegistry(devices)
    local data = state.get()
    local summary = machines.summary()
    local list = {}
    local me = false
    for address, kind in pairs(devices or {}) do
        list[#list + 1] = { address = address, kind = kind }
        if kind == "fluid_interface" or kind == "me_interface" then me = true end
    end
    data.facts.hardware.summary = summary
    data.facts.hardware.me = me

    local missing = {}
    if summary.host == 0 then missing[#missing + 1] = "净水厂主机" end
    if not me then missing[#missing + 1] = "ME网络接口" end
    if not summary.energy then missing[#missing + 1] = "能量仓" end
    data.facts.hardware.missing = missing

    rebuildLevels()
    facts.publish(data.facts.hardware, list)
end

--- 完成一次扫描对账，持久化拓扑并发布硬件登记事实。
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
    if host_cycle.needsSample(now) then due.hostProgress = now end
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

--- 推进一次设备发现、命名和坐标补全任务。
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
        local name, nameErr = device.name(task.address)
        if not name and nameErr then
            log.diag(string.format("机器名称读取失败 %s：%s",
                util.shortAddress(task.address), tostring(nameErr)))
        end
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

    local x, y, z, coordErr = device.coordinates(task.address)
    if x ~= nil and y ~= nil and z ~= nil then
        machines.update(task.address, nil, x, y, z)
    elseif coordErr then
        log.diag(string.format("机器坐标读取失败 %s：%s",
            util.shortAddress(task.address), tostring(coordErr)))
    end
    return completeScanTask(scanState)
end
--- 读取能源仓功率；失败时保留上一次有效功率并记录错误。
local function stepEnergy(now)
    local hatch = machines.energy()
    local data = state.get()
    local power
    local reason

    if hatch then
        local stored, err = device.invoke(hatch.address, "getEUMaxStored")
        if type(stored) == "number" then
            power = energy.powerOf(hatch, stored)
        else
            reason = tostring(err or "能源存量不是数值")
        end
    else
        reason = "能量仓不存在"
    end

    if power ~= nil then
        local before = data.power.max
        local firstObservation = data.power.observedAt == nil
        local hadError = data.power.error ~= nil
        data.power.max = power
        data.power.available = math.floor(power * (data.settings.energyFactor or 100) / 100)
        data.power.observedAt = clock.uptime()
        data.power.error = nil
        if before ~= power or firstObservation or hadError then state.bump() end
    elseif data.power.error ~= reason then
        data.power.error = reason
        state.bump()
    end

    due.energy = now + INTERVAL.energy
    return false
end

--- 读取并发布 T1-T8 水位；失败时保留旧水位。
local function stepWater(now)
    local data = state.get()
    local levels, err = fluid.readAll(data.facts.hardware.value or {})
    if levels ~= nil then
        facts.publish(data.facts.water, levels)
    elseif facts.fail(data.facts.water, err or "水位读取失败") then
        log.warn("水位读取失败：" .. tostring(err or "未知错误"))
    end
    due.water = now + INTERVAL.water
    return false
end

--- 读取并发布主机开关；失败时保留旧值。
local function stepHostSwitch(now)
    local host = machines.of(constants.HOST_LEVEL)[1]
    local fact = state.get().facts.host.switch
    if host then
        local previous = fact.value
        local value, err = probes.switch(host.address)
        if value ~= nil then
            facts.publish(fact, value)
            if value ~= previous then
                local changed = host_cycle.setRunning(value, now)
                if changed and value then due.hostProgress = now end
            end
        elseif facts.fail(fact, err or "主机开关读取失败") then
            log.warn("主机开关读取失败：" .. tostring(err or "未知错误"))
        end
    elseif facts.fail(fact, "净水主机不存在") then
        log.warn("主机开关读取失败：净水主机不存在")
    end
    due.hostSwitch = now + INTERVAL.hostSwitch
    return false
end

--- 条件采样真实进度，其余时间仅推进本地 uptime 进度时钟。
local function stepHostProgress(now)
    local host = machines.of(constants.HOST_LEVEL)[1]
    if not host then
        hostProgressState = nil
        due.hostProgress = math.huge
        return false
    end

    local data = state.get()
    if not hostProgressState then
        if host_cycle.needsSample(now) then
            hostProgressState = { phase = "progress" }
            return true
        end

        local started = host_cycle.tick(now)
        if started then
            activeRequested = true
            due.active = now
        end
        due.hostProgress = host_cycle.nextDue(now)
        return false
    end

    if hostProgressState.phase == "progress" then
        local value, err = probes.progress(host.address)
        if value == nil then
            facts.fail(data.facts.host.progress, err or "主机进度读取失败")
            host_cycle.sampleFailed()
            hostProgressState = nil
            due.hostProgress = host_cycle.nextDue(now)
            return false
        end
        hostProgressState = { phase = "max", progress = value }
        return true
    end

    local maxProgress, maxErr = probes.progressMax(host.address)
    if maxProgress == nil then
        facts.fail(data.facts.host.progressMax, maxErr or "主机总进度读取失败")
        maxProgress = data.facts.host.progressMax.value
    end
    local started = host_cycle.observe(hostProgressState.progress, maxProgress, now)
    hostProgressState = nil
    if started then
        activeRequested = true
        due.active = now
    end
    due.hostProgress = host_cycle.nextDue(now)
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

--- 逐台读取 T1-T8 开关；失败时保留旧值并记录错误。
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
    local value, err = probes.switch(machine.address)
    if value ~= nil then
        fact.switch = value
        fact.switchErr = nil
        fact.switchObservedAt = clock.uptime()
        if previous ~= nil and previous ~= value then
            learning_service.clearLevel(level)
        end
    else
        fact.switchErr = tostring(err or "机器开关读取失败")
    end
    return true
end

--- 逐台读取活跃机器传感器，并提交本周期学习样本。
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
        local info, err = probes.sensor(machine.address)
        if info then
            fact.parallel = info.parallel
            fact.success = info.success
            fact.sampleErr = nil
            fact.sampleObservedAt = clock.uptime()
            local seq = host_cycle.seq()
            if fact.active == true and seq > 0 and seq == plantSampleState.sampleSeq
                and fact.learnedCycle ~= seq then
                fact.learnedCycle = seq
                learning_service.observe(level, machine.address, info.parallel, info.success, seq)
            end
        else
            fact.sampleErr = tostring(err or "传感器读取失败")
        end
    end
    return true
end

--- 按需逐台刷新 T1-T8 的活跃状态。
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
    local value, err = probes.active(machine.address)
    if value ~= nil then
        fact.active = value
        fact.activeErr = nil
        fact.activeObservedAt = clock.uptime()
    else
        fact.activeErr = tostring(err or "机器运行状态读取失败")
    end
    return true
end

local PENDING = {
    { key = "scan", state = function() return scanState end, run = stepScan },
    { key = "active", state = function() return activeState end, run = function() return stepActive() end },
    { key = "plantSwitch", state = function() return plantSwitchState end, run = stepPlantSwitch },
    { key = "plantSample", state = function() return plantSampleState end, run = stepPlantSample },
    { key = "hostProgress", state = function() return hostProgressState end, run = stepHostProgress },
}

--- 返回硬件状态机下一次需要推进的时间。
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

--- 至多执行一个硬件扫描或观测步骤。
function service.step(now)
    for _, item in ipairs(PENDING) do
        if item.state() then return item.run(now) end
    end

    local order = { "scan", "active", "plantSwitch", "plantSample", "hostSwitch", "hostProgress", "energy", "water" }
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

--- 请求立即重新扫描并刷新全部硬件属性。
function service.requestRefresh()
    scanState = nil
    forceRefresh = true
    host_cycle.requestSample()
    due.scan = 0
end

--- 从硬件登记文件恢复机器表并重建等级聚合。
function service.load()
    machines.load(hardware_store.loadLines())
    machines.consumeChanged()
    rebuildLevels()
    host_cycle.requestSample()
    due.hostProgress = 0
end

return service