--------------------------------------------------------------------------------
-- PurifyWater/services/host_cycle.lua
--
-- 定位：净水主机周期边沿检测器。
-- 功能：观察主机进度变化，识别新周期并维护单调周期序号。
-- 边界：只维护周期号，不读取组件，也不触发制作任务。
--------------------------------------------------------------------------------

local state = require("services.state")
local facts = require("services.facts")

local host_cycle = {}
local armed = false

--- 用主机进度边沿检测新周期并递增周期序号。
function host_cycle.observe(progress, maxProgress)
    if type(progress) ~= "number" then return false end
    local data = state.get()
    local cycle = data.facts.host.cycle
    local previous = cycle.progress

    local progressFact = data.facts.host.progress
    facts.publish(progressFact, progress)
    if type(maxProgress) == "number" then
        facts.publish(data.facts.host.progressMax, maxProgress)
    end

    if previous == nil then
        armed = progress <= 1
        cycle.progress = progress
        return false
    end
    if progress < previous and progress <= 1 then armed = true end

    local started = (progress < previous and progress > 1)
        or (armed and previous <= 1 and progress > 1)
    cycle.progress = progress
    if not started then return false end

    armed = false
    cycle.seq = (cycle.seq or 0) + 1
    cycle.detectedAt = progressFact.observedAt
    return true, cycle.seq
end

--- 返回最近识别到的周期序号。
function host_cycle.seq()
    return state.get().facts.host.cycle.seq or 0
end

return host_cycle
