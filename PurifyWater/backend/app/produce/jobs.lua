--------------------------------------------------------------------------------
-- backend/app/produce/jobs.lua
--------------------------------------------------------------------------------
-- 【职责】T0 周期边沿、operation 登记、周期门控、过期 job 取消
-- 【不做什么】不执行转运、不维护绑定/侧位/库存
--------------------------------------------------------------------------------

local computer       = require("computer")
local CONFIG         = require("shared.config")
local constants      = require("shared.constants")
local logs           = require("shared.logs")
local state          = require("shared.state")
local scheduler      = require("core.scheduler")
local produce        = require("backend.domain.produce")
local interface      = require("backend.domain.produce.interface")
local binding        = require("backend.app.produce.binding")
local readiness      = require("backend.app.produce.readiness")
local produceRuntime = require("backend.app.produce_runtime")
local produceJob     = require("backend.app.produce_job")

local jobs = {}

-- 启动后的首次周期观测：只有确认从周期起点开始才允许补发第一次边界。
local cycleStartArmed = false

local function cycleRatio()
    local cycle = state.read.produce().cycle
    local progress, max = cycle.lastProgress, cycle.progressMax
    if type(progress) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
    return progress / max
end

--- 同一周期内某台机器是否仍允许继续推进
local function sameCycleAllowed(job, seq)
    return state.read.produce().cycle.seq == seq
        and readiness.machineAllowed(job.machine, job.level, job.sub)
end

--- 创建一个 operation job
local function addOperation(machine, sub, method, seq)
    local id = string.format("job:%d:%s", sub.level, machine)
    if produceRuntime.has(id) or (sub.cycleSeq or 0) == seq then return false end
    local job = produceJob.new(machine, sub, interface.operation(method),
        interface.recoversTargetItems(method))
    job.id           = id
    job.levelLabel   = constants.levelLabel(sub.level)
    job.machineText  = binding.machineTextOf(sub.level, machine)
    job.priority     = interface.priority(method) or 20
    job.cycleSeq     = seq
    job.runAt        = computer.uptime()
    job.gate         = function() return sameCycleAllowed(job, seq) end
    produceRuntime.add(job)
    state.write.produceSetSub(machine, { cycleSeq = seq })
    return true
end

--- 取消当前不再允许的 job
function jobs.sync()
    local seq = state.read.produce().cycle.seq
    return produceRuntime.cancelWhere(function(job)
        return not sameCycleAllowed(job, seq)
    end)
end

--- 周期边界检测
function jobs.onCycleProgress(progress, maxProgress)
    if type(progress) ~= "number" then return end
    local cycle = state.read.produce().cycle
    local prev = cycle.lastProgress
    state.write.produceSetCycle({ lastProgress = progress, progressMax = maxProgress })

    if prev == nil then
        cycleStartArmed = (progress <= 1)
        return
    end
    if progress < prev and progress <= 1 then cycleStartArmed = true end

    local newCycle = (progress < prev and progress > 1)
        or (cycleStartArmed and prev <= 1 and progress > 1)
    if not newCycle then return end

    cycleStartArmed = false
    local seq = (cycle.seq or 0) + 1
    state.write.produceSetCycle({ seq = seq })
    scheduler.emit("produce_cycle", { seq = seq })
end

--- 周期开始：清旧 job，按当前门控登记本周期 job
function jobs.onCycleStarted(payload)
    local seq = (payload and payload.seq) or state.read.produce().cycle.seq
    local dropped = produceRuntime.cancelWhere(function(job)
        return job.cycleSeq ~= seq
    end)
    if dropped > 0 then
        logs.debug(string.format("制作自动化：周期 #%s 丢弃未完成 operation %d 个",
            tostring(seq), dropped))
    end

    local ratio = cycleRatio()
    if ratio and ratio > (tonumber(CONFIG.PRODUCE.CYCLE_CUTOFF) or 0.9) then
        logs.debug(string.format("制作自动化：周期 #%s 已过 %d%%，不登记任务",
            tostring(seq), math.floor(ratio * 100)))
        return
    end

    local planned = 0
    for machine, sub in pairs(state.read.produce().subs) do
        local method = produce.method(sub.level)
        if method and type(interface.operation(method)) == "function"
            and readiness.machineAllowed(machine, sub.level, sub)
            and addOperation(machine, sub, method, seq) then
            planned = planned + 1
        end
    end
    if planned > 0 then
        logs.debug(string.format("制作自动化：周期 #%s 登记 operation %d 台",
            tostring(seq), planned))
    end
end

return jobs
