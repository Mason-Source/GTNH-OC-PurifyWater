-- 日志落盘任务：业务只入队，按固定周期批量写盘。
local CONFIG = require("shared.config")
local clock = require("services.clock")
local log = require("services.log")

local service = {}
local dueAt = 0
local INTERVAL = (CONFIG.LOG and CONFIG.LOG.FLUSH_INTERVAL) or 5

function service.load(now)
    dueAt = (tonumber(now) or clock.uptime()) + INTERVAL
    return true
end

function service.step(now)
    if now < dueAt then return false end
    dueAt = now + INTERVAL
    local ok, err = log.flush()
    if not ok then log.error("日志保存失败：" .. tostring(err)) end
    return false
end

---@diagnostic disable-next-line: unused-local
function service.nextDue(now) return dueAt end

return service