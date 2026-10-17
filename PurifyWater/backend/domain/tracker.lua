--------------------------------------------------------------------------------
-- backend/domain/tracker.lua
--------------------------------------------------------------------------------
-- 【职责】并行采样 -> 可信的唯一判定：连续 N 个运行周期同值
-- 【不做什么】不写学习值（那是 domain/learning）、不算功率（那是 domain/power）
-- 【依赖】shared/config、shared/state
-- 【被谁用】backend/app/watch（parallel_sample 事件）
--
-- 并行在配方周期内恒定、周期之间变：连续 N 个周期同值才稳定。
-- 周期边界 = produce 周期钟的 seq 变化（T3 边沿检测）；seq 不可读 = 异常：不结算、不猜周期。
-- 结算用上一周期最后一次读到的值（并行在周期内恒定，与"周期最后一次读数"等价）。
--
-- tracker[address] = { seq, value, settled, streak, confirmed }
--   seq 上次周期号；value 本周期最后一次读数；settled 上一周期结算值；streak 连续同值数；
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

--- 喂一个采样
-- @param address string 机器地址
-- @param value number 本次读到的并行
-- @param seq number|nil produce 周期号（nil = 读取失败）
-- @return string "write"|"discard"
-- @return string why 说明（写日志用）
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
        -- 首读：记下本周期号和值，等下一周期结算
        state.write.trackerSet(address, { seq = seq, value = value })
        return "discard", string.format("首读 %d（待下一周期结算）", value)
    end

    if seq == t.seq then
        -- 同周期：并行在周期内恒定，记最后一次读数
        t.value = value
        return "discard", string.format("本周期读到 %d（周期未结束）", value)
    end

    -- 周期号不连续（停机 / 没采样）：上一周期的值不可信，重新累积
    if seq ~= t.seq + 1 then
        t.seq, t.value, t.settled, t.streak = seq, value, nil, 0
        return "discard", "周期不连续（重新累积）"
    end

    -- 新周期：用上一周期最后一次读数结算
    local settled = t.value
    t.seq, t.value = seq, value
    if t.settled == settled then
        t.streak = math.min(limit(), (t.streak or 0) + 1) -- 计满即止，等值变化
    else
        t.streak = 1
    end
    t.settled = settled
    if t.streak >= limit() then
        if t.confirmed == settled then
            -- 已确认过的值：熄火（不重复 write；watch 的"与学习值相同"闸门是第二道防线）
            return "discard", string.format("与已确认值相同（%d）", settled)
        end
        -- 逐台确认值（详情页展示）
        t.confirmed = settled
        return "write", string.format("连续 %d 个运行周期均为 %d", limit(), settled)
    end
    return "discard", string.format("周期值 %d（%d/%d 个周期）", settled, t.streak, limit())
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
