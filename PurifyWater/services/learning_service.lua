--------------------------------------------------------------------------------
-- PurifyWater/services/learning_service.lua
--
-- 定位：并行与成功率的周期学习服务。
-- 功能：要求同一机器连续多个周期保持一致，确认后写入 plan.learned。
-- 边界：只在调度运行期间学习；不参与建议计算，不直接读取传感器。
--------------------------------------------------------------------------------

local CONFIG = require("shared.config")
local constants = require("shared.constants")
local state = require("services.state")
local control = require("services.control")

local learning = {}
local tracker = {}

local function limit()
    return math.max(1, CONFIG.RATES.PARALLEL_CONFIRM_CYCLES or 3)
end

--- 提交单个周期样本，并在连续一致后写入学习并行值。
function learning.observe(level, address, parallel, success, seq)
    local data = state.get()
    if not control.isRunning(data) then return false end
    if type(parallel) ~= "number" or parallel <= 0 or type(seq) ~= "number" then
        tracker[address] = nil
        return false
    end

    local item = tracker[address]
    if not item then
        tracker[address] = { level = level, seq = seq, value = parallel, streak = 1 }
        return false
    end
    if item.seq == seq then return false end
    if item.seq ~= seq - 1 then
        item.level, item.seq, item.value, item.streak, item.confirmed = level, seq, parallel, 1, nil
        return false
    end

    item.level = level
    item.seq = seq
    if item.value == parallel then item.streak = (item.streak or 1) + 1 else
        item.value, item.streak, item.confirmed = parallel, 1, nil
    end
    if item.streak < limit() or item.confirmed == parallel then return false end

    item.streak, item.confirmed = limit(), parallel
    local learned = data.plan.learned[level] or {}
    local changed = learned.parallel ~= parallel or (success ~= nil and learned.success ~= success)
    data.plan.learned[level] = {
        parallel = parallel,
        success = success,
        source = "measured",
    }
    if changed then
        state.bump()
    end
    return changed
end

--- 返回指定机器已经确认的学习并行值。
function learning.confirmed(address)
    local item = tracker[address]
    return item and item.confirmed or nil
end

--- 清除指定等级所有机器的学习跟踪。
function learning.clearLevel(level)
    for address, item in pairs(tracker) do
        if item.level == level then tracker[address] = nil end
    end
end

--- 清除全部跟踪与已学习值。
function learning.resetAll()
    tracker = {}
    local data = state.get()
    local changed = false
    for level = 1, constants.LEVEL_COUNT do
        local learned = data.plan.learned[level]
        if learned and learned.parallel ~= nil then changed = true end
        data.plan.learned[level] = nil
    end
    if changed then state.bump() end
    return changed
end

--- 返回已有有效学习值的等级数量。
function learning.count()
    local count = 0
    for level = 1, constants.LEVEL_COUNT do
        local item = state.get().plan.learned[level]
        if item and type(item.parallel) == "number" and item.parallel > 0 then count = count + 1 end
    end
    return count
end

return learning