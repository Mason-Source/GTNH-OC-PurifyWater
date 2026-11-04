--------------------------------------------------------------------------------
-- PurifyWater/services/host_cycle.lua
--
-- 定位：净水主机周期边沿检测与本地进度时钟。
-- 功能：条件采样真实进度，用 uptime 游戏刻外推显示进度，并在预测周期边界递增序号。
-- 边界：只维护周期状态；常规运行不轮询组件，采样由硬件服务按条件触发。
--------------------------------------------------------------------------------

local config = require("shared.config")
local state = require("services.state")
local facts = require("services.facts")

local host_cycle = {}

local TICKS_PER_SECOND = (config.HOST_PROGRESS and config.HOST_PROGRESS.TICKS_PER_SECOND) or 20
local SAFETY_TICKS = (config.HOST_PROGRESS and config.HOST_PROGRESS.SAFETY_TICKS) or 1
local UI_INTERVAL = (config.INTERVAL and config.INTERVAL.HOST_PROGRESS) or 3

local model = {
    confirmedProgress = nil,
    confirmedMax = nil,
    sampledAt = nil,
    estimatedProgress = nil,
    estimatedMax = nil,
    nextDisplayAt = 0,
    sampleRequested = true,
    running = nil,
    frozen = false,
}
local armed = false

local function requestSample()
    model.sampleRequested = true
    model.nextDisplayAt = 0
end

local function sample(progress, maxProgress, now)
    if type(progress) ~= "number" then return false, "progress is not numeric" end
    now = tonumber(now) or 0
    maxProgress = tonumber(maxProgress) or model.confirmedMax

    local data = state.get()
    local cycle = data.facts.host.cycle
    local previous = cycle.progress

    facts.publish(data.facts.host.progress, progress)
    if type(maxProgress) == "number" then
        facts.publish(data.facts.host.progressMax, maxProgress)
    end

    if previous == nil then
        armed = progress <= 1
    elseif progress < previous and progress <= 1 then
        armed = true
    end

    local started = previous ~= nil and (
        (progress < previous and progress > 1)
        or (armed and previous <= 1 and progress > 1)
    )
    cycle.progress = progress
    if started then
        armed = false
        cycle.seq = (cycle.seq or 0) + 1
        cycle.detectedAt = data.facts.host.progress.observedAt
    end

    model.confirmedProgress = progress
    model.confirmedMax = maxProgress
    model.sampledAt = now
    model.estimatedProgress = progress
    model.estimatedMax = maxProgress
    model.nextDisplayAt = now + UI_INTERVAL
    model.sampleRequested = false
    return started, cycle.seq
end

local function sampleFailed()
    model.sampleRequested = false
end

local function setRunning(running, now)
    running = running == true
    local previous = model.running
    model.running = running

    if previous == nil then
        model.frozen = not running
        return false
    end
    if previous == running then return false end

    if not running then
        model.frozen = true
        model.nextDisplayAt = math.huge
        return true
    end

    model.frozen = false
    requestSample()
    return true
end

local function tick(now, force)
    now = tonumber(now) or 0
    if model.frozen or not model.confirmedProgress or not model.confirmedMax then
        return false
    end
    if not force and now < model.nextDisplayAt then return false end

    local maxProgress = model.confirmedMax
    local elapsed = math.max(0, now - (model.sampledAt or now))
    local rawTicks = math.floor(elapsed * TICKS_PER_SECOND + 0.000001)
    local safeTicks = math.max(0, rawTicks - SAFETY_TICKS)
    local remaining = math.max(0, maxProgress - model.confirmedProgress)

    if remaining > 0 and safeTicks >= remaining then
        -- The safety lag guarantees this rollover is never predicted early.
        local data = state.get()
        local cycle = data.facts.host.cycle
        cycle.seq = (cycle.seq or 0) + 1
        cycle.detectedAt = now
        cycle.progress = 0
        armed = false
        model.confirmedProgress = 0
        model.sampledAt = now
        model.estimatedProgress = 0
        model.nextDisplayAt = now + UI_INTERVAL
        state.bump()
        return true
    end

    local estimated = math.min(maxProgress, model.confirmedProgress + safeTicks)
    if estimated ~= model.estimatedProgress then
        model.estimatedProgress = estimated
        state.bump()
    end
    model.nextDisplayAt = now + UI_INTERVAL
    return false
end

local function view()
    local data = state.get()
    return {
        progress = model.estimatedProgress or data.facts.host.progress.value,
        progressMax = model.estimatedMax or data.facts.host.progressMax.value,
    }
end

local function nextDue(now)
    if model.sampleRequested then return tonumber(now) or 0 end
    if model.sampledAt == nil or model.frozen or not model.confirmedMax then return math.huge end
    return model.nextDisplayAt
end

local function needsSample(now)
    return model.sampleRequested
end

--- 条件采样真实主机进度并重置 uptime 锚点。
function host_cycle.observe(progress, maxProgress, now)
    return sample(progress, maxProgress, now)
end

--- 请求在下一个硬件步骤补采一次真实进度。
function host_cycle.requestSample()
    requestSample()
end

--- 条件采样失败后取消本次请求，等待下一次条件事件。
function host_cycle.sampleFailed()
    sampleFailed()
end

--- 根据主机开关冻结或恢复本地进度时钟。
function host_cycle.setRunning(running, now)
    return setRunning(running, now)
end

--- 推进本地进度显示；返回是否预测进入了新周期。
function host_cycle.tick(now, force)
    return tick(now, force)
end

--- 返回当前显示进度与最大进度。
function host_cycle.view()
    return view()
end

--- 返回本地进度时钟下一次需要推进或采样的时间。
function host_cycle.nextDue(now)
    return nextDue(now)
end

--- 判断是否需要进行一次条件采样。
function host_cycle.needsSample(now)
    return needsSample(now)
end

--- 返回最近识别或预测到的周期序号。
function host_cycle.seq()
    return state.get().facts.host.cycle.seq or 0
end

return host_cycle
