local CONFIG  = require("shared.config")
local state   = require("shared.state")
local tracker = {}
local function limit()
    return math.max(1, CONFIG.PARALLEL_CONFIRM_CYCLES or 3)
end
function tracker.feed(address, value, seq)
    if type(value) ~= "number" or value <= 0 then
        tracker.reset(address)
        return "discard", "并行读数无效"
    end
    if type(seq) ~= "number" then
        return "discard", "周期号不可读（不结算）"
    end
    local t = state.read.tracker()[address]
    if not t then
        state.write.trackerSet(address, { seq = seq, value = value })
        return "discard", string.format("首读 %d（待下一周期结算）", value)
    end
    if seq == t.seq then
        t.value = value
        return "discard", string.format("本周期读到 %d（周期未结束）", value)
    end
    if seq ~= t.seq + 1 then
        t.seq, t.value, t.settled, t.streak = seq, value, nil, 0
        return "discard", "周期不连续（重新累积）"
    end
    local settled = t.value
    t.seq, t.value = seq, value
    if t.settled == settled then
        t.streak = math.min(limit(), (t.streak or 0) + 1)
    else
        t.streak = 1
    end
    t.settled = settled
    if t.streak >= limit() then
        if t.confirmed == settled then
            return "discard", string.format("与已确认值相同（%d）", settled)
        end
        t.confirmed = settled
        return "write", string.format("连续 %d 个运行周期均为 %d", limit(), settled)
    end
    return "discard", string.format("周期值 %d（%d/%d 个周期）", settled, t.streak, limit())
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
