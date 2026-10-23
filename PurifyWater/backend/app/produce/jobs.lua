--------------------------------------------------------------------------------
-- backend/app/produce/jobs.lua
--------------------------------------------------------------------------------
-- 【职责】消费 host_cycle_started、制作任务登记、周期门控、过期 job 取消
-- 【不做什么】不执行转运、不维护绑定/侧位/库存
--------------------------------------------------------------------------------

local computer       = require("computer")
local CONFIG         = require("shared.config")
local constants      = require("shared.constants")
local state          = require("shared.state")
local hostCycle      = require("backend.domain.host_cycle")
local produce        = require("backend.domain.produce")
local interface      = require("backend.domain.produce.interface")
local binding        = require("backend.app.produce.binding")
local readiness      = require("backend.app.produce.readiness")
local produceRuntime = require("backend.app.produce_runtime")
local produceJob     = require("backend.app.produce_job")

local jobs = {}

--- 同一周期内某台机器是否仍允许继续推进
local function sameCycleAllowed(job, seq)
    return hostCycle.seq() == seq
        and readiness.machineAllowed(job.machine, job.level, job.sub)
end

--- 创建一个制作任务 job
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
    local seq = hostCycle.seq()
    return produceRuntime.cancelWhere(function(job)
        return not sameCycleAllowed(job, seq)
    end)
end

--- 周期开始：清旧 job，按当前门控登记本周期 job
function jobs.onCycleStarted(payload)
    local seq = (payload and payload.seq) or hostCycle.seq()
    produceRuntime.cancelWhere(function(job)
        return job.cycleSeq ~= seq
    end)

    local ratio = payload and payload.ratio
    if ratio and ratio > (tonumber(CONFIG.PRODUCE.CYCLE_CUTOFF) or 0.9) then
        return
    end

    for machine, sub in pairs(state.read.produce().subs) do
        local method = produce.method(sub.level)
        if method and type(interface.operation(method)) == "function"
            and readiness.machineAllowed(machine, sub.level, sub) then
            addOperation(machine, sub, method, seq)
        end
    end
end

return jobs
