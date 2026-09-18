local CONFIG  = require("shared.config")
local state   = require("shared.state")
local tracker = {}
local function limit()
    return math.max(1, CONFIG.PARALLEL_CONFIRM_CYCLES or 3)
end
function tracker.feed(address, value, progress)
    if type(value) ~= "number" or value <= 0 then
        tracker.reset(address)
        return "discard", "并行读数无效"
    end
    local t = state.tracker[address]
    if not t then
        state.tracker[address] = {
            progress   = tonumber(progress),
            cycleValue = value,
            samples    = 1
        }
        return "discard", string.format("首读 %d（等第 1 个运行周期结束）", value)
    end
    t.cycleValue = value
    local closed = false
    if type(progress) == "number" and type(t.progress) == "number" then
        if progress < t.progress then closed = true end
        t.progress = progress
    else
        t.samples = (t.samples or 0) + 1
        if t.samples >= math.max(1, CONFIG.PARALLEL_FALLBACK_SAMPLES or 24) then
            t.samples = 0
            closed    = true
        end
    end
    if not closed then
        return "discard", string.format("本周期读到 %d（等周期结束）", value)
    end
    if t.value == value then
        t.streak = (t.streak or 0) + 1
    else
        t.value, t.streak = value, 1
    end
    if t.streak >= limit() then
        t.streak    = 0
        t.confirmed = value
        return "write", string.format("连续 %d 个运行周期均为 %d", limit(), value)
    end
    return "discard", string.format("周期值 %d（%d/%d 个周期）", value, t.streak, limit())
end
function tracker.reset(address)
    state.tracker[address] = nil
end
function tracker.clear(list)
    for _, item in ipairs(list or {}) do
        local address = (type(item) == "table") and item.address or item
        if address then state.tracker[address] = nil end
    end
end
function tracker.resetAll()
    state.tracker = {}
end
return tracker
