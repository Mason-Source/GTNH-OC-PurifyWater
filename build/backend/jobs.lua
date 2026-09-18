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
local levels_config    = require("backend.store.levels_config")
local records          = require("backend.store.records")
local history          = require("backend.store.history")
local log_file         = require("backend.store.log_file")
local power            = require("backend.domain.power")
local plan             = require("backend.app.plan")
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
local lastParallelWarn = nil
local startedAt        = computer.uptime()
local memwatch         = nil
function jobs.elapsed()
    return computer.uptime() - startedAt
end
function jobs.last() return last end
function jobs.scanHardware()
    device.invalidate()
    local summary    = machines.scan()
    local hatch      = machines.energy()
    local totalPower = energy.powerOf(hatch)
    if hatch then hatch.power = totalPower end
    local meProxy = device.me()
    local missing = {}
    if summary.host == 0 then missing[#missing + 1] = "净水厂主机" end
    if not meProxy then missing[#missing + 1] = "ME网络接口" end
    if not hatch then missing[#missing + 1] = "能量仓" end
    local diff              = inventory.compareAndSave(machines.topology())
    last.scanCount          = last.scanCount + 1
    last.summary            = summary
    last.meOk, last.missing = meProxy ~= nil, missing
    state.power.all         = totalPower
    local warnParts         = {}
    for _, item in ipairs(power.parallelMismatch()) do
        warnParts[#warnParts + 1] = string.format("%s 当前 %s / 建议 %s", constants.levelLabel(item.level),
            utils.formatShortNumber(item.current), utils.formatShortNumber(item.suggest))
    end
    local warnText = table.concat(warnParts, "；")
    if warnText ~= lastParallelWarn then
        lastParallelWarn = warnText
        if warnText ~= "" then
            logs.warn("当前并行与建议并行不一致：" .. warnText)
        end
    end
    if #missing > 0 then
        scheduler.emit("hardware_missing", { missing = missing })
    end
    if diff.changed then
        scheduler.emit("hardware_changed", diff)
    end
    if last.powerBefore ~= nil and math.floor(last.powerBefore) ~= math.floor(totalPower) then
        scheduler.emit("power_changed", { from = last.powerBefore, to = totalPower })
    end
    last.powerBefore = totalPower
    logs.debug(string.format("[调试] 硬件扫描 #%d：主机 %d、单元 %d、能量仓 %s、其它 %d、总功率 %s、缺失 %s",
        last.scanCount, summary.host, summary.unitTotal, hatch and hatch.name or "无", summary.other,
        utils.formatNumber(totalPower), (#missing > 0 and table.concat(missing, "/") or "无")))
end
function jobs.readFluids()
    local changed, why = levels_config.load()
    if changed then
        scheduler.emit("level_rules_changed", { why = why })
    end
    local amounts, ok, err = fluid.readAll()
    last.fluidOk, last.fluidErr = ok, err
    for level = 1, constants.LEVEL_COUNT do
        local amount = ok and amounts[level] or nil
        state.fluids[level] = amount
        if amount == nil then
            scheduler.emit("fluid_unavailable", { level = level, reason = err })
        else
            scheduler.emit("fluid_state", { level = level, amount = amount })
        end
    end
end
function jobs.observePlants()
    local samples, runningTotal = 0, 0
    local hostAllowed = nil
    local hostProgress, hostProgressMax
    for level = constants.HOST_LEVEL, constants.LEVEL_COUNT do
        local list                 = machines.of(level)
        local snap                 = state.plant(level)
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
        snap.deployed = total
        snap.switch   = observed
        snap.active   = (total > 0 and actFail == 0) and running or nil
        snap.machines = facts
        if minSample then snap.sample = minSample end
        if minSuccess then snap.success = minSuccess end
        runningTotal = runningTotal + running
        if level == constants.HOST_LEVEL then
            snap.progress    = hostProgress
            snap.progressMax = hostProgressMax
            hostAllowed      = snap.switch
        end
        if total > 0 then
            scheduler.emit("plant_observed", {
                level = level, switch = observed, active = snap.active, deployed = total
            })
        end
    end
    logs.debug(string.format("[调试] 观测：单元在跑 %d 台，本轮采样 %d 条", runningTotal, samples))
end
function jobs.schedule()
    if state.isActive() then plan.run("定时") end
end
function jobs.persist()
    if memwatch then memwatch.watch(jobs.elapsed()) end
    history.append()
    state.markDirty("history")
    if state.isDirty("records") then
        local ok, text = records.save(nil)
        logs.debug("[调试] T5 写并行记录：" .. tostring(text))
        if ok then state.clearDirty("records") end
    end
    if state.isDirty("levels") then
        levels_config.saveAll()
        state.clearDirty("levels")
    end
    local ok, text = history.save()
    if not ok then logs.debug("[调试] T5 写历史失败：" .. tostring(text)) end
    local okLog, logNote = log_file.flush()
    if not okLog then logs.debug("[调试] T5 写日志失败：" .. tostring(logNote)) end
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
    jobs.scanHardware()
    jobs.readFluids()
    jobs.observePlants()
    return n
end
return jobs
