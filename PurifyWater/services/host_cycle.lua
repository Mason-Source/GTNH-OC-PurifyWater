-- T0 周期边沿检测；只维护周期号，不读取组件。
local state = require("services.state")

local host_cycle = {}
local armed = false

function host_cycle.observe(progress, maxProgress)
    if type(progress) ~= "number" then return false end
    local data = state.get()
    local cycle = data.facts.host.cycle
    local previous = cycle.progress

    data.facts.host.progress.value = progress
    data.facts.host.progress.observedAt = require("services.clock").uptime()
    if type(maxProgress) == "number" then
        data.facts.host.progressMax.value = maxProgress
        data.facts.host.progressMax.observedAt = data.facts.host.progress.observedAt
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
    cycle.detectedAt = data.facts.host.progress.observedAt
    return true, cycle.seq
end

function host_cycle.seq()
    return state.get().facts.host.cycle.seq or 0
end

return host_cycle
