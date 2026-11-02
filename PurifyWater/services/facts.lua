--------------------------------------------------------------------------------
-- PurifyWater/services/facts.lua
--
-- 定位：观测事实发布、失败记录与可用性查询工具。
-- 功能：维护 value/observedAt/error，计算年龄，并返回 ready/pending/error。
-- 边界：不决定何时观测；旧值继续可信，未知值保持 nil，不以 false 或 0 冒充。
--------------------------------------------------------------------------------

local clock = require("services.clock")
local state = require("services.state")

local facts = {}

--- 写入事实成功值、清除错误并记录观测时间。
function facts.publish(slot, value)
    slot.value = value
    slot.error = nil
    slot.observedAt = clock.uptime()
    state.bump()
end

--- 记录一次观测失败；已有旧值继续保留并视为可用。
---@return boolean changed 错误信息是否发生变化。
function facts.fail(slot, err)
    local text = tostring(err or "观测失败")
    local changed = slot.error ~= text
    slot.error = text
    if changed then state.bump() end
    return changed
end

--- 返回事实槽当前可用性：ready/pending/error。
--- 有已发布值时优先信任旧值；只有从未成功时才返回 pending/error。
---@return string status 事实状态。
---@return string|nil reason 非 ready 状态的原因。
function facts.status(slot)
    if not slot then return "pending", "事实槽不存在" end
    if slot.value ~= nil then return "ready" end
    if slot.error ~= nil then return "error", tostring(slot.error) end
    return "pending", "尚未观测"
end

--- 返回事实距当前时刻的秒数；从未观测时返回 nil。
function facts.age(slot)
    if not slot or not slot.observedAt or slot.observedAt == 0 then return nil end
    return math.max(0, clock.uptime() - slot.observedAt)
end

--- 判断事实是否已观测且晚于指定时间。
function facts.isFresh(slot, afterAt)
    return slot ~= nil and slot.value ~= nil
        and slot.observedAt > (tonumber(afterAt) or 0)
end

return facts
