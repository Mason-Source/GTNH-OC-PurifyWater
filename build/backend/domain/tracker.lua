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
    local t = state.read.tracker()[address]
    if not t then
        state.write.trackerSet(address, {
            progress = tonumber(progress)
        })
        return "discard", string.format("首读 %d（待首周期结束）", value)
    end
    if type(progress) ~= "number" then
        return "discard", "进度不可读（不结算）"
    end
    local closed = false
    if type(t.progress) == "number" and progress < t.progress then closed = true end
    t.progress = progress
    if not closed then
        return "discard", string.format("本周期读到 %d（周期未结束）", value)
    end
    if t.value == value then
        t.streak = math.min(limit(), (t.streak or 0) + 1)
    else
        t.value, t.streak = value, 1
    end
    if t.streak >= limit() then
        if t.confirmed == value then
            return "discard", string.format("与已确认值相同（%d）", value)
        end
        t.confirmed = value
        return "write", string.format("连续 %d 个运行周期均为 %d", limit(), value)
    end
    return "discard", string.format("周期值 %d（%d/%d 个周期）", value, t.streak, limit())
end
function tracker.reset(address)
    state.write.trackerDelete(address)
end
function tracker.clear(list)
    for _, item in ipairs(list or {}) do
        local address = (type(item) == "table") and item.address or item
        if address then state.write.trackerDelete(address) end
    end
end
function tracker.resetAll()
    state.write.trackerReset()
end
return tracker
