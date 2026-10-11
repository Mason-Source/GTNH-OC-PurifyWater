local constants = require("shared.constants")
local logs      = require("shared.logs")
local state     = require("shared.state")
local scheduler = require("core.scheduler")
local tracker   = require("backend.domain.tracker")
local machines  = require("backend.hardware.machines")
local system    = require("backend.app.system")
local watch     = {}
function watch.onLevelRulesChanged(payload)
    logs.debug("[调试] " .. tostring(payload and payload.why or "阈值配置已更新"))
    system.auditThresholds()
    system.requestPlan("阈值变化")
end
function watch.onRatesChanged(payload)
    logs.debug("[调试] " .. tostring(payload and payload.why or "速率配置已更新"))
    system.auditThresholds()
    system.requestPlan("权重变化")
end
function watch.onPlantObserved(payload)
    local level     = payload.level
    local snap      = state.plant(level)
    local prev      = snap.lastSwitch
    snap.lastSwitch = payload.switch
    if level == constants.HOST_LEVEL then
        if prev ~= nil and payload.switch ~= nil and prev ~= payload.switch then
            logs.append(payload.switch
                and "[系统] 主机开关已打开（不会自动恢复调度，请点【启动系统】）"
                or "[警告] 主机开关已关闭 -> 全关并锁定")
        end
        if payload.switch == false then
            system.ensureHostStoppedLock()
        end
        return
    end
    local edge = (prev ~= nil and payload.switch ~= nil and prev ~= payload.switch)
    if edge then
        logs.system(string.format("%s 开关%s", constants.levelLabel(level),
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
    if not state.isActive() then return end
    local verdict, why = tracker.feed(payload.address, payload.parallel, payload.progress)
    if verdict ~= "write" then
        scheduler.emit("parallel_discarded", {
            level = payload.level, value = payload.parallel, why = why
        })
        return
    end
    local snap = state.plant(payload.level)
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
    logs.debug(string.format("[调试] %s 并行采样丢弃：%s（%s）",
        constants.levelLabel(payload.level), tostring(payload.value), tostring(payload.why)))
end
return watch
