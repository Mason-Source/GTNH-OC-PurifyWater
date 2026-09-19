local CONFIG      = require("shared.config")
local constants   = require("shared.constants")
local logs        = require("shared.logs")
local state       = require("shared.state")
local utils       = require("shared.utils")
local scheduler   = require("core.scheduler")
local rules       = require("backend.domain.rules")
local power       = require("backend.domain.power")
local tracker     = require("backend.domain.tracker")
local records     = require("backend.store.records")
local machines    = require("backend.hardware.machines")
local plan        = require("backend.app.plan")
local system      = require("backend.app.system")
local watch       = {}
local warnedFluid = false
function watch.onFluidState(payload)
    local level                             = payload.level
    state.fluids[level]                     = payload.amount
    warnedFluid                             = false
    local snap                              = state.plant(level)
    local before                            = snap.openable
    local verdict                           = rules.evaluate(level)
    snap.openable, snap.forced, snap.reason = verdict.open, verdict.forced, verdict.reason
    if before ~= nil and before ~= verdict.open then
        logs.system(string.format("%s 开启条件%s：%s", constants.levelLabel(level),
            verdict.open and "满足" or "不满足", verdict.reason))
        scheduler.emit("level_openable_changed", {
            level = level, open = verdict.open, forced = verdict.forced, reason = verdict.reason
        })
    end
end
function watch.onFluidUnavailable(payload)
    if warnedFluid then return end
    warnedFluid = true
    logs.warn(string.format("水位读不到（%s）——停机并锁定，接回 ME 网络后请手动点【启动系统】",
        tostring(payload and payload.reason or "原因未知")))
    if state.isActive() then
        system.enterSafeState("水位读不到", false)
    end
end
function watch.onLevelRulesChanged(payload)
    logs.debug("[调试] " .. tostring(payload and payload.why or "阈值配置已更新"))
    for level = 1, constants.LEVEL_COUNT do
        local verdict                           = rules.evaluate(level)
        local snap                              = state.plant(level)
        snap.openable, snap.forced, snap.reason = verdict.open, verdict.forced, verdict.reason
    end
    if state.isActive() then plan.run("阈值变化") end
end
function watch.onLevelOpenableChanged()
    if state.isActive() then plan.run("开启条件变化") end
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
        scheduler.emit("unit_switched", { level = level, on = payload.switch })
    end
    if payload.switch == nil then return end
    local want = state.lastPlan[level]
    if want == nil then
        state.cmd[level] = nil
        return
    end
    local cmd = payload.cmd
    if cmd == nil then return end
    if state.cmd[level] == cmd then state.cmd[level] = nil end
    if payload.switch ~= cmd.want then
        scheduler.emit("switch_mismatch", {
            level = level, want = cmd.want, got = payload.switch
        })
    end
end
function watch.onParallelSample(payload)
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
            level = payload.level, value = payload.parallel, why = "与记录相同"
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
function watch.onParallelWrite(payload)
    local ok, text = records.save(payload.level, payload.parallel, payload.success)
    logs.system(string.format("%s 实际并行 = %s（来源：%s）%s",
        constants.levelLabel(payload.level), utils.formatShortNumber(payload.parallel),
        tostring(payload.by or "-"), ok and "" or "【写盘失败】"))
    power.refresh()
    if state.isActive() then plan.run("并行更新") end
    return ok, text
end
function watch.onScheduleNow(payload)
    if not state.isActive() then return end
    plan.run(payload and payload.reason or "事件")
end
return watch
