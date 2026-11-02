--------------------------------------------------------------------------------
-- PurifyWater/services/log_flush.lua
--
-- 定位：日志批量落盘的固定工作表。
-- 功能：按配置周期调用 log.flush，将内存队列写入当前日志卷。
-- 边界：不生成业务日志，不解释日志内容。
--------------------------------------------------------------------------------

local CONFIG = require("shared.config")
local clock = require("services.clock")
local log = require("services.log")

local service = {}
local dueAt = 0
local INTERVAL = (CONFIG.LOG and CONFIG.LOG.FLUSH_INTERVAL) or 5

--- 安排下一次日志批量落盘时间。
function service.load(now)
    dueAt = (tonumber(now) or clock.uptime()) + INTERVAL
    return true
end

--- 到期时调用 log.flush 并安排下一次落盘。
function service.step(now)
    if now < dueAt then return false end
    dueAt = now + INTERVAL
    local ok, err = log.flush()
    if not ok then log.error("日志保存失败：" .. tostring(err)) end
    return false
end

--- 返回下一次日志落盘时间。
---@param now number 当前时间。
---@return number dueAt 下一次到期时间。
---@diagnostic disable-next-line: unused-local
function service.nextDue(now) return dueAt end

return service