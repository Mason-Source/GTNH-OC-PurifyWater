-- 固定工作表：扫描服务自行管理内部截止时间，工作层只做统一调度。
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

local function itemDue(item, now)
    if item.nextDue then return item.nextDue(now) end
    return data.work[item.name].dueAt
end

function work.nextDue(now)
    local best = now + config.LOOP_MAX_IDLE
    for _, item in ipairs(order) do
        local value = itemDue(item, now)
        if value < best then best = value end
    end
    return best
end

function work.select(now)
    for _, item in ipairs(order) do
        if now >= itemDue(item, now) then return item end
    end
end

function work.after(item, now, more)
    local slot = data.work[item.name]
    if more then
        slot.dueAt = now
    elseif item.nextDue then
        slot.dueAt = item.nextDue(now)
    else
        slot.dueAt = now + item.interval
    end
end

return work