local constants = require("shared.constants")
local logs      = require("shared.logs")
local state     = require("shared.state")
local utils     = require("shared.utils")
local scheduler = require("core.scheduler")
local tracker   = require("backend.domain.tracker")
local power     = require("backend.domain.power")
local machines  = require("backend.hardware.machines")
local system    = require("backend.app.system")
local watch     = {}
local lastMismatchWarn = {}
function watch.onLevelRulesChanged(payload)
    logs.debug(tostring(payload and payload.why or "阈值配置已更新"))
    system.auditThresholds()
    system.requestPlan("阈值变化")
end
local function warnParallelMismatch(level, snap)
    if not state.read.running() then
        lastMismatchWarn[level] = nil
        return
    end
    local sample = snap.sample
    local text
    if sample and (snap.deployed or 0) > 0 then
        local suggest = power.suggest(level)
        if sample ~= suggest then
            text = string.format("%s 当前 %s / 建议 %s", constants.levelLabel(level),
                utils.formatShortNumber(sample), utils.formatShortNumber(suggest))
        end
    end
    if text ~= lastMismatchWarn[level] then
        lastMismatchWarn[level] = text
        if text then logs.warn("当前并行与建议并行不一致：" .. text) end
    end
end
function watch.onPlantObserved(payload)
    local level     = payload.level
    local snap      = state.read.plant(level)
    local prev      = snap.lastSwitch
    state.write.setLastSwitch(level, payload.switch)
    if level == constants.HOST_LEVEL then
        if payload.switch == false and (prev == nil or prev == true) then
            logs.append("[警告] 主机未开机；请开启净水主机")
        elseif payload.switch == true and prev == false then
            logs.append("[系统] 主机已开机；不会自动恢复调度，点【启动系统】恢复")
        end
        if payload.switch == false then
            system.ensureHostStopped()
        end
        return
    end
    warnParallelMismatch(level, snap)
    local edge = (prev ~= nil and payload.switch ~= nil and prev ~= payload.switch)
    if edge then
        logs.system(string.format("%s 机器%s", constants.levelLabel(level),
            payload.switch and "打开" or "关闭"))
        tracker.clear(machines.of(level))
    end
    if payload.switch == nil then return end
    local want = payload.want
    if want == nil or payload.switch == want then return end
    scheduler.emit("switch_mismatch", {
        level = level, want = want, got = payload.switch
    })
end
function watch.onParallelSample(payload)
    if not state.read.running() then return end
    local verdict, why = tracker.feed(payload.address, payload.parallel, payload.progress)
    if verdict ~= "write" then
        scheduler.emit("parallel_discarded", {
            level = payload.level, value = payload.parallel, why = why
        })
        return
    end
    local snap = state.read.plant(payload.level)
    if snap.source == "measured" and snap.parallel == payload.parallel then
        scheduler.emit("parallel_discarded", {
            level = payload.level, value = payload.parallel, why = "与学习值相同"
        })
        return
    end
    scheduler.emit("parallel_write", {
        level = payload.level,
        address = payload.address,
        parallel = payload.parallel,
        success = payload.success,
        by = "传感器确认"
    })
end
function watch.onParallelDiscarded(payload)
    logs.debug(string.format("%s 并行采样丢弃：%s（%s）",
        constants.levelLabel(payload.level), tostring(payload.value), tostring(payload.why)))
end
return watch
