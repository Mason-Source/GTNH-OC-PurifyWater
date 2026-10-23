--------------------------------------------------------------------------------
-- backend/domain/tracker.lua
--------------------------------------------------------------------------------
-- 【职责】周期开始并行样本 -> 可信的唯一判定：连续 N 个运行周期同值
-- 【不做什么】不写学习值（那是 domain/learning）、不算功率（那是 domain/power）
-- 【依赖】shared/config、shared/state
-- 【被谁用】backend/app/watch（host_cycle_started）
--
-- 每个运行周期只在 host_cycle_started 事件里收到一次样本；不做周期内最后一次读数覆盖。
--
-- tracker[address] = { seq, value, streak, confirmed }
--   seq 上次周期号；value 本周期采样值；streak 连续同值周期数；
--   confirmed 已确认学习并行（详情页逐台展示；同值不再重复 write）。
--------------------------------------------------------------------------------

local CONFIG  = require("shared.config")
local state   = require("shared.state")

local tracker = {}

--- 要连续几个周期同值才算可信
-- @return number
local function limit()
    return math.max(1, CONFIG.PARALLEL_CONFIRM_CYCLES or 3)
end

--- 喂一个周期开始样本
-- @param address string 机器地址
-- @param value number 本周期开始读到的并行
-- @param seq number|nil produce 周期号（nil = 读取失败）
-- @return string "write"|"discard"
function tracker.feed(address, value, seq)
    if type(value) ~= "number" or value <= 0 or type(seq) ~= "number" then
        tracker.reset(address)
        return "discard"
    end

    local t = state.read.tracker()[address]
    if not t then
        state.write.trackerSet(address, { seq = seq, value = value, streak = 1 })
        return "discard"
    end

    -- 同一周期只允许一次学习采样；重复事件直接忽略。
    if seq == t.seq then return "discard" end

    -- 周期号不连续（停机 / 漏采样）：从本周期重新累积。
    if seq ~= t.seq + 1 then
        t.seq, t.value, t.streak = seq, value, 1
        return "discard"
    end

    local streak = (t.value == value) and ((t.streak or 1) + 1) or 1
    t.seq, t.value = seq, value
    if streak >= limit() and t.confirmed ~= value then
        t.streak, t.confirmed = limit(), value
        return "write"
    end
    t.streak = streak
    return "discard"
end

--- 复位单台（开关变化/停机时读数无效）
-- @param address string
function tracker.reset(address)
    state.write.trackerDelete(address)
end

--- 清一批机器（增删/开关变化时调用）
-- @param list table 机器表数组（{address=...}）或地址数组
function tracker.clear(list)
    for _, item in ipairs(list or {}) do
        local address = (type(item) == "table") and item.address or item
        if address then state.write.trackerDelete(address) end
    end
end

--- 全清（硬件变更、系统停机时用）
function tracker.resetAll()
    state.write.trackerReset()
end

return tracker
