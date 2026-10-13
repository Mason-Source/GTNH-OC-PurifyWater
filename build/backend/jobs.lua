local computer         = require("computer")
local scheduler        = require("core.scheduler")
local CONFIG           = require("shared.config")
local constants        = require("shared.constants")
local logs             = require("shared.logs")
local state            = require("shared.state")
local utils            = require("shared.utils")
local device           = require("backend.hardware.device")
local machines         = require("backend.hardware.machines")
local probes           = require("backend.hardware.probes")
local energy           = require("backend.hardware.energy")
local fluid            = require("backend.hardware.fluid")
local inventory        = require("backend.store.inventory")
local settings         = require("backend.store.settings")
local levels_config    = require("backend.store.levels_config")
local rates_config     = require("backend.store.rates_config")
local history          = require("backend.store.history")
local log_file         = require("backend.store.log_file")
local system           = require("backend.app.system")
local jobs             = {}
local last             = {
    scanCount = 0,
    summary = nil,
    powerBefore = nil,
    meOk = false,
    missing = {},
    fluidOk = false,
    fluidErr = nil
}
local startedAt        = computer.uptime()
local memwatch         = nil
function jobs.elapsed()
    return computer.uptime() - startedAt
end
function jobs.last() return last end
function jobs.scanHardware()
    device.sweep()
    device.scanMe()
    device.scanNet()
    device.scanMachines()
    local summary = machines.classify()
    local hatch   = machines.energy()
    local euMax
    if hatch then
        local stored = device.invoke(hatch.address, "getEUMaxStored")
        if type(stored) == "number" then euMax = stored end
    end
    local totalPower, powerNote = energy.powerOf(hatch, euMax)
    if hatch then hatch.power = totalPower end
    local meProxy = device.me()
    local missing = {}
    if summary.host == 0 then missing[#missing + 1] = "净水厂主机" end
    if not meProxy then missing[#missing + 1] = "ME网络接口" end
    if not hatch then missing[#missing + 1] = "能量仓" end
    local diff = inventory.compareAndSave(machines.topology())
    local prevMissing = last.missing
    last.scanCount          = last.scanCount + 1
    last.summary            = summary
    last.meOk, last.missing = meProxy ~= nil, missing
    if #prevMissing > 0 and #missing == 0 then
        logs.system("硬件缺失已恢复：" .. table.concat(prevMissing, "、") .. "；点【启动系统】恢复")
    elseif #prevMissing == 0 and #missing > 0 then
        logs.warn("硬件缺失：" .. table.concat(missing, "、") .. "；请补齐缺失硬件")
    end
    local prevAll = state.read.powerAll()
    if state.read.powerMax() ~= totalPower then
        state.write.setPowerMax(totalPower)
    end
    if #missing > 0 then
        scheduler.emit("hardware_missing", { missing = missing })
    end
    if diff.changed then
        scheduler.emit("hardware_changed", diff)
    end
    local nowAll = state.read.powerAll()
    if prevAll ~= nowAll then
        scheduler.emit("power_changed", { from = prevAll, to = nowAll, note = powerNote })
    end
    last.powerBefore = totalPower
    logs.debug(string.format("硬件扫描 #%d：主机 %d、单元 %d、能量仓 %s、网卡 %s、其它 %d、总功率 %s、缺失 %s",
        last.scanCount, summary.host, summary.unitTotal, hatch and hatch.name or "无",
        device.net() and "有" or "无", summary.other,
        utils.formatNumber(totalPower), (#missing > 0 and table.concat(missing, "/") or "无")))
end
function jobs.scanSettings()
    local snapshot = settings.load() or {}
    local changed, why = levels_config.load(snapshot)
    if changed then
        scheduler.emit("level_rules_changed", { why = why })
    end
    local ratesChanged, ratesWhy = rates_config.load(snapshot)
    if ratesChanged then
        scheduler.emit("rates_changed", { why = ratesWhy })
    end
end
function jobs.readFluids()
    local amounts, ok, err = fluid.readAll()
    last.fluidOk, last.fluidErr = ok, err
    local fluids = {}
    for level = 1, constants.LEVEL_COUNT do
        fluids[level] = (ok and amounts[level]) or 0
    end
    state.write.setFluids(fluids)
end
function jobs.observePlants()
    local samples, runningTotal = 0, 0
    local hostAllowed = nil
    local hostProgress, hostProgressMax
    local deployedLevels = {}
    for level = constants.HOST_LEVEL, constants.LEVEL_COUNT do
        local list                 = machines.of(level)
        local snap                 = state.read.plant(level)
        local want                 = state.read.lastPlan()[level]
        local total, on, off, fail = 0, 0, 0, 0
        local running, actFail     = 0, 0
        local facts                = {}
        local minSample, minSuccess
        for _, machine in ipairs(list) do
            total     = total + 1
            local sw  = probes.switch(machine.address)
            local act = probes.active(machine.address)
            if level == constants.HOST_LEVEL and sw ~= false then
                hostProgress, hostProgressMax = probes.progress(machine.address)
            end
            local fact = { address = machine.address, switch = sw, active = act }
            if sw == true then
                on = on + 1
            elseif sw == false then
                off = off + 1
            else
                fail = fail + 1
            end
            if act == true then running = running + 1 end
            if act == nil then actFail = actFail + 1 end
            facts[#facts + 1] = fact
            if level >= 1 and act == true and hostAllowed ~= false then
                local info  = probes.sensor(machine.address)
                local value = info and info.parallel
                if type(value) == "number" then
                    local success = info and info.success or nil
                    fact.parallel = value
                    fact.success  = success
                    if not minSample or value < minSample then minSample = value end
                    if success and (not minSuccess or success < minSuccess) then minSuccess = success end
                    samples = samples + 1
                    scheduler.emit("parallel_sample", {
                        level    = level,
                        address  = machine.address,
                        parallel = value,
                        success  = success,
                        progress = hostProgress
                    })
                end
            end
        end
        local observed = nil
        if total > 0 and fail == 0 then
            if on == total then
                observed = true
            elseif off == total then
                observed = false
            end
        end
        local deployed = snap.deployed or 0
        if deployed ~= total then
            deployed = total
            deployedLevels[#deployedLevels + 1] = level
        end
        local fields = {
            deployed = deployed,
            switch   = observed,
            active   = (total > 0 and actFail == 0) and running or nil,
            machines = facts
        }
        if minSample then fields.sample = minSample end
        if minSuccess then fields.success = minSuccess end
        if level == constants.HOST_LEVEL then
            fields.progress    = hostProgress
            fields.progressMax = hostProgressMax
        end
        state.write.recordPlant(level, fields)
        runningTotal = runningTotal + running
        if level == constants.HOST_LEVEL then
            hostAllowed = observed
        end
        if total > 0 then
            scheduler.emit("plant_observed", {
                level = level, switch = observed, active = snap.active, deployed = total, want = want
            })
        end
    end
    if #deployedLevels > 0 then
        scheduler.emit("deployed_changed", { levels = deployedLevels })
    end
    logs.debug(string.format("观测：单元在跑 %d 台，本轮采样 %d 条", runningTotal, samples))
end
function jobs.schedule()
    system.requestPlan("定时")
end
function jobs.persist()
    if memwatch then memwatch.watch(jobs.elapsed()) end
    history.append()
    local ok, text = history.save()
    if not ok then logs.debug("T5 写历史失败：" .. tostring(text)) end
    local okLog, logNote = log_file.flush()
    if not okLog then logs.debug("T5 写日志失败：" .. tostring(logNote)) end
end
function jobs.register()
    local n = 0
    local function add(...)
        if scheduler.every(...) then n = n + 1 end
    end
    add("scanHardware", CONFIG.INTERVAL.HARDWARE, jobs.scanHardware)  
    add("readFluids", CONFIG.INTERVAL.FLUID, jobs.readFluids)         
    add("observePlants", CONFIG.INTERVAL.OBSERVE, jobs.observePlants) 
    add("schedule", CONFIG.INTERVAL.SCHEDULE, jobs.schedule)          
    add("persist", CONFIG.INTERVAL.PERSIST, jobs.persist)             
    if logs.isDebug() then
        memwatch = require("backend.debug.memwatch")
        add("sampleMemory", CONFIG.INTERVAL.SAMPLE, memwatch.sample) 
    end
    jobs.scanSettings()
    jobs.scanHardware()
    jobs.readFluids()
    jobs.observePlants()
    return n
end
return jobs
