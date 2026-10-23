--------------------------------------------------------------------------------
-- backend/domain/host_cycle.lua
--------------------------------------------------------------------------------
-- 【职责】主机 T0 周期边沿检测、周期号维护
-- 【不做什么】不读组件、不登记制作任务、不做并行学习
-- 【依赖】shared/state
-- 【被谁用】backend/jobs（检测）、produce/watch（消费 host_cycle_started）
--
-- 周期进度由 jobs.observePlants 读取；本模块只判断边沿并更新中性 hostCycle 状态。
--------------------------------------------------------------------------------

local state = require("shared.state")

local hostCycle = {}
local cycleStartArmed = false

--- 喂一次主机周期进度
-- @param progress number|nil
-- @param maxProgress number|nil
-- @return boolean started 是否检测到新周期
-- @return number|nil seq 新周期号
-- @return number|nil ratio 当前周期进度比例
function hostCycle.observe(progress, maxProgress)
    if type(progress) ~= "number" then return false end

    local cycle = state.read.hostCycle()
    local prev  = cycle.lastProgress
    state.write.setHostCycleProgress(progress, maxProgress)

    if prev == nil then
        cycleStartArmed = (progress <= 1)
        return false
    end
    if progress < prev and progress <= 1 then cycleStartArmed = true end

    local started = (progress < prev and progress > 1)
        or (cycleStartArmed and prev <= 1 and progress > 1)
    if not started then return false end

    cycleStartArmed = false
    local seq = (cycle.seq or 0) + 1
    state.write.setHostCycle({ seq = seq })
    local ratio = (type(maxProgress) == "number" and maxProgress > 0)
        and (progress / maxProgress) or nil
    return true, seq, ratio
end

--- 当前周期号
-- @return number
function hostCycle.seq()
    return state.read.hostCycle().seq or 0
end

return hostCycle
