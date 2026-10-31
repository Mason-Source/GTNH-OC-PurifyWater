-- 事实发布与新鲜度判断。
local clock = require("services.clock")
local state = require("services.state")

local facts = {}

function facts.publish(slot, value)
    slot.value = value
    slot.observedAt = clock.uptime()
    state.bump()
end

function facts.age(slot)
    if not slot or not slot.observedAt or slot.observedAt == 0 then return nil end
    return math.max(0, clock.uptime() - slot.observedAt)
end

function facts.isFresh(slot, afterAt)
    return slot ~= nil and slot.value ~= nil
        and slot.observedAt > (tonumber(afterAt) or 0)
end

return facts
