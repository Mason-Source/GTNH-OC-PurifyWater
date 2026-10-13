--------------------------------------------------------------------------------
-- backend/domain/tracker.lua
--------------------------------------------------------------------------------
-- 【职责】并行采样 -> 可信的唯一判定：连续 N 个运行周期同值
-- 【不做什么】不写学习值（那是 domain/learning）、不算功率（那是 domain/power）
-- 【依赖】shared/config、shared/state
-- 【被谁用】backend/app/watch（parallel_sample 事件）
--
-- 并行在配方周期内恒定、周期之间变：连续 N 个周期同值才稳定。
-- 周期边界 = 进度回落；进度读不到 = 异常：不结算、不猜周期，等恢复。
-- 结算用"进度回落那一拍"读到的值；并行在周期内恒定，与"周期最后一次读数"等价。
--
-- tracker[address] = { progress, value, streak, confirmed }
--   progress 上次进度；value 上周期结算值；streak 连续同值数；
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
-- @param progress number|nil 本次进度（判周期边界；nil = 读取失败）
-- @return string "write"|"discard"
-- @return string why 说明（写日志用）
function tracker.feed(address, value, progress)
    if type(value) ~= "number" or value <= 0 then
        tracker.reset(address)
        return "discard", "并行读数无效"
    end

    local t = state.read.tracker()[address]
    if not t then
        -- 首读：只记进度，等首周期结束
        state.write.trackerSet(address, {
            progress = tonumber(progress)
        })
        return "discard", string.format("首读 %d（待首周期结束）", value)
    end


    -- ① 周期结束？进度回落算结束。读不到进度 = 异常：不结算（等恢复，不猜周期）
    if type(progress) ~= "number" then
        return "discard", "进度不可读（不结算）"
    end
    local closed = false
    if type(t.progress) == "number" and progress < t.progress then closed = true end
    t.progress = progress
    if not closed then
        return "discard", string.format("本周期读到 %d（周期未结束）", value)
    end

    -- ② 周期结算：连续同值？
    if t.value == value then
        t.streak = math.min(limit(), (t.streak or 0) + 1) -- 计满即止，等值变化
    else
        t.value, t.streak = value, 1
    end
    if t.streak >= limit() then
        if t.confirmed == value then
            -- 已确认过的值：熄火（不重复 write；watch 的"与学习值相同"闸门是第二道防线）
            return "discard", string.format("与已确认值相同（%d）", value)
        end
        -- 逐台确认值（详情页展示）
        t.confirmed = value
        return "write", string.format("连续 %d 个运行周期均为 %d", limit(), value)
    end
    return "discard", string.format("周期值 %d（%d/%d 个周期）", value, t.streak, limit())
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
