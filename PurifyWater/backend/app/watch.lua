--------------------------------------------------------------------------------
-- backend/app/watch.lua
--------------------------------------------------------------------------------
-- 【职责】把事实事件变成判断与动作：开关边沿、归因、并行不一致、采样可信化
-- 【依赖】domain/{tracker,power}、app/system、shared/*
-- 【被谁用】backend/handlers.lua
--
-- jobs 只报读到什么，这里做判断；实测 vs 读数那一刻方案：
--   一致无事；偏离 = 人或外部线路动过，停会话 + 等待用户；无方案可对照不判。
-- 等待用户唯一入口 = system.enterAwaiting。
--------------------------------------------------------------------------------

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

-- 上一句"并行不一致"警告（逐级独立边沿：文本变才再报）
local lastMismatchWarn = {}

--- 阈值文件变更（T2 检测到 -> 审计提示 + 立刻重排）
-- @param payload table { why }
function watch.onLevelRulesChanged(payload)
    logs.debug(tostring(payload and payload.why or "阈值配置已更新"))
    system.auditThresholds()
    system.requestPlan("阈值变化")
end

--- 实测并行 ≠ 建议 -> 打一行（逐级各自记边沿；不自作结论）
-- @param level number
-- @param snap table 该级快照（state.read.plant(level)）
local function warnParallelMismatch(level, snap)
    -- 只在自动调度中报；不在跑时清本级边沿，恢复运行后第一句照报
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

--- 观测事实（T3 -> 5 秒一次，T0-8 每级一行）
-- @param payload table { level, switch, active, deployed, want }（want = 读数那一刻该级的方案）
function watch.onPlantObserved(payload)
    local level     = payload.level
    local snap      = state.read.plant(level)
    local prev      = snap.lastSwitch
    state.write.setLastSwitch(level, payload.switch)

    -- 主机：开关关（边沿 / 首次读到）提示一行；运行中则全关停机（幂等）；不发事件。
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

    -- 并行不一致（实测 sample vs 建议）：逐级判、逐级记边沿
    warnParallelMismatch(level, snap)

    -- 单元边沿：记日志 + 采样复位
    local edge = (prev ~= nil and payload.switch ~= nil and prev ~= payload.switch)
    if edge then
        logs.system(string.format("%s 机器%s", constants.levelLabel(level),
            payload.switch and "打开" or "关闭"))
        tracker.clear(machines.of(level))
    end

    if payload.switch == nil then return end

    -- 用 payload.want（读数那一刻方案）而非 lastPlan：T3 先于 T4 注册，
    -- 到 drain 时 lastPlan 可能已换，会把一致旧读数误判；want==nil 不判。
    local want = payload.want
    if want == nil or payload.switch == want then return end

    -- 偏离 = 人或外部线路动过 -> 停会话 + 等待用户
    scheduler.emit("switch_mismatch", {
        level = level, want = want, got = payload.switch
    })
end

--- 并行采样（只对在跑单元读）
-- 过渡值不直接写，连续 N 个运行周期同值才算数（判定在 tracker）。
-- @param payload table { level, address, parallel, success, progress }
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

--- 采样被丢弃（只写调试，不进用户日志——否则每 5 秒刷一屏）
-- @param payload table { level, value, why }
function watch.onParallelDiscarded(payload)
    logs.debug(string.format("%s 并行采样丢弃：%s（%s）",
        constants.levelLabel(payload.level), tostring(payload.value), tostring(payload.why)))
end

return watch
