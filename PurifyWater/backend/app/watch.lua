--------------------------------------------------------------------------------
-- backend/app/watch.lua
--------------------------------------------------------------------------------
-- 【职责】把**事实事件**变成**判断与动作**：开关边沿、归因、不一致、采样可信化
-- 【依赖】domain/tracker、app/system、shared/*
-- 【被谁用】backend/handlers.lua
--
-- 【事实 vs 判断】jobs 只报"读到了什么"，所有"这意味着什么"都在这里：
--   plant_observed    -> 边沿(日志) + 偏离判定(switch_mismatch) + 主机开关对齐
--   parallel_sample   -> tracker 连续确认 -> parallel_write / parallel_discarded
--   level_rules_changed / rates_changed -> 审计提示 + 立刻重排
--
-- 【判定放在这里】实测开关 vs **读数那一刻的方案**（payload.want，随事实一起上来）：
--   一致 -> 无事；**偏离 -> 只可能是人（或外部线路）动过机器** -> 停机 + 锁定，
--   机器保持原状、程序不再替用户做决定（偏离本身就是证据，不需要再猜是谁发的命令）。
--   没有方案可对照（停机 / 还没跑过 / 上一轮没发出去）-> 不判。
-- 【进锁只有一个入口】`system.enterSafeState(why, allOff, line)` —— 幂等与"只报一次"都在那里，
--   这里只负责拼出 `why` 与那一行说明，不持有任何去重标志。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local logs      = require("shared.logs")
local state     = require("shared.state")

local scheduler = require("core.scheduler")

local tracker   = require("backend.domain.tracker")

local machines  = require("backend.hardware.machines")

local system    = require("backend.app.system")

local watch     = {}

--- 阈值文件变更（T2 检测到 -> 审计提示 + 立刻重排）
-- @param payload table { why }
function watch.onLevelRulesChanged(payload)
    -- 行数统计属排查信息：改完阈值后，界面上的新值本身就是回执。
    logs.debug("[调试] " .. tostring(payload and payload.why or "阈值配置已更新"))
    system.auditThresholds()
    system.requestPlan("阈值变化")
end

--- 速率配置变更（T2 检测到 -> 审计提示 + 立刻重排）
-- @param payload table { why }
function watch.onRatesChanged(payload)
    logs.debug("[调试] " .. tostring(payload and payload.why or "速率配置已更新"))
    system.auditThresholds()
    system.requestPlan("权重变化")
end

--- 观测事实（T3 -> 5 秒一次，T0-8 每级一行）
-- @param payload table { level, switch, active, deployed, want }（want = 读数那一刻该级的方案）
function watch.onPlantObserved(payload)
    local level     = payload.level
    local snap      = state.plant(level)
    local prev      = snap.lastSwitch
    snap.lastSwitch = payload.switch

    -- 主机（0 级）：开关边沿只写一行证据，处理统一走"每轮对齐一次"（幂等）。
    -- 不发 host_switch_on/off 事件：处理已是电平语义，边沿事件只会重复同一件事。
    if level == constants.HOST_LEVEL then
        if prev ~= nil and payload.switch ~= nil and prev ~= payload.switch then
            logs.append(payload.switch
                and "[系统] 主机开关已打开（不会自动恢复调度，请点【启动系统】）"
                or "[警告] 主机开关已关闭 -> 全关并锁定")
        end
        -- 主机停机 -> 每轮对齐一次"全关 + 锁定"（幂等）：程序启动时主机已关的情形没有边沿
        if payload.switch == false then
            system.ensureHostStoppedLock()
        end
        return
    end

    -- 单元开关边沿：记日志 + 采样复位（刚开关时传感器读到的数不可信）
    local edge = (prev ~= nil and payload.switch ~= nil and prev ~= payload.switch)
    if edge then
        logs.system(string.format("%s 开关%s", constants.levelLabel(level),
            payload.switch and "打开" or "关闭"))
        tracker.clear(machines.of(level))
    end

    if payload.switch == nil then return end

    -- 【判定只有一处：实测 vs **读数那一刻的方案**（payload.want）】
    --   为什么用 payload.want 而不是 state.lastPlan：T3 在同一帧里跑在 T4 前面（注册序），
    --   而这里的处理要等本帧 drain 才跑 —— 那一刻 lastPlan 可能已经换成新方案了（事件驱动的
    --   重排也在 drain 里）。拿新方案比旧读数，就会把"一致的旧读数"判成"人动过"。
    --   want == nil（停机 / 还没跑过 / 上一轮没发出去）-> 没有方案可对照，不判。
    local want = payload.want
    if want == nil or payload.switch == want then return end

    -- 偏离方案 = 只可能是人（或外部线路）动过机器 -> 停机 + 锁定，机器保持原状
    scheduler.emit("switch_mismatch", {
        level = level, want = want, got = payload.switch
    })
end

--- 并行采样（T3：只对"正在运行"的单元读；progress 用来判运行周期边界）
-- 【不直接写盘】刚开机/刚改并行时传感器会吐过渡值，连续 N 个运行周期同值才算数
--   （判定全部交给 domain/tracker）
-- @param payload table { level, address, parallel, success, progress }
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

--- 采样被丢弃（只写调试，不进用户日志——否则每 5 秒刷一屏）
-- @param payload table { level, value, why }
function watch.onParallelDiscarded(payload)
    logs.debug(string.format("[调试] %s 并行采样丢弃：%s（%s）",
        constants.levelLabel(payload.level), tostring(payload.value), tostring(payload.why)))
end

return watch
