--------------------------------------------------------------------------------
-- PurifyWater/services/work.lua
--
-- 定位：固定后台工作表与统一调度器。
-- 功能：按固定优先级选择到期服务步骤，处理截止时间、立即续跑和失败退避。
-- 边界：不实现具体业务；每轮最多执行一个工作表步骤。
--------------------------------------------------------------------------------

local config = require("shared.config")
local state = require("services.state")
local hardware_service = require("services.hardware_service")
local history_service = require("services.history_service")
local produce_service = require("services.produce_service")
local schedule_service = require("services.schedule_service")
local produce_runtime = require("services.produce_runtime")
local net_service = require("services.net_service")
local log_flush = require("services.log_flush")

local work = {}
local data = state.get()
local backoff = {}

local order = {
    {
        name = "hardware",
        run = hardware_service.step,
        nextDue = hardware_service.nextDue,
    },
    {
        name = "history",
        run = history_service.step,
        nextDue = history_service.nextDue,
    },
    {
        name = "produce",
        run = produce_service.step,
        nextDue = produce_service.nextDue,
    },
    {
        name = "schedule",
        run = schedule_service.step,
        nextDue = schedule_service.nextDue,
    },
    {
        name = "produce_runtime",
        run = produce_runtime.step,
        nextDue = produce_runtime.nextDue,
    },
    {
        name = "net",
        run = net_service.step,
        nextDue = net_service.nextDue,
    },
    {
        name = "log_flush",
        run = log_flush.step,
        nextDue = log_flush.nextDue,
    },

}

--- 返回工作表项在考虑失败退避后的截止时间。
local function itemDue(item, now)
    local blockedUntil = backoff[item.name]
    if blockedUntil and blockedUntil > now then return blockedUntil end
    if item.nextDue then return item.nextDue(now) end
    return data.work[item.name].dueAt
end

--- 返回固定工作表中最近的到期时间。
function work.nextDue(now)
    local best = now + config.LOOP_MAX_IDLE
    for _, item in ipairs(order) do
        local value = itemDue(item, now)
        if value < best then best = value end
    end
    return best
end

--- 按固定优先级返回第一个到期服务步骤。
function work.select(now)
    for _, item in ipairs(order) do
        if now >= itemDue(item, now) then return item end
    end
end

--- 记录步骤完成时间并安排下一截止时间。
function work.after(item, now, more)
    backoff[item.name] = nil
    local slot = data.work[item.name]
    if more then
        slot.dueAt = now
    elseif item.nextDue then
        slot.dueAt = item.nextDue(now)
    else
        slot.dueAt = now + item.interval
    end
end

--- 为失败步骤设置短暂退避。
function work.fail(item, now)
    backoff[item.name] = now + 5
end

return work