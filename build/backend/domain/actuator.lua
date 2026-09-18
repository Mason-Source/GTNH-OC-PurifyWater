local constants = require("shared.constants")
local state     = require("shared.state")
local computer  = require("computer")
local device    = require("backend.hardware.device")
local machines  = require("backend.hardware.machines")
local actuator  = {}
local receipt   = { at = 0, items = {} }
function actuator.apply(plan)
    local now    = computer.uptime()
    receipt      = { at = now, items = {} }
    local count  = 0
    local failed = {}
    for level = 1, constants.LEVEL_COUNT do
        local list = machines.of(level)
        if #list > 0 then
            local want = plan[level] == true
            for _, m in ipairs(list) do
                local item = { level = level, address = m.address, want = want, ok = true }
                local _, err = device.invoke(m.address, "setWorkAllowed", want)
                if err then
                    item.ok, item.err = false, err
                    failed[level]     = tostring(err)
                end
                receipt.items[#receipt.items + 1] = item
                count = count + 1
            end
            state.cmd[level] = { want = want, at = now }
        end
    end
    return count, failed
end
function actuator.shutdownAll()
    return actuator.apply({})
end
function actuator.lastReceipt()
    return receipt
end
function actuator.describeReceipt()
    local failed = 0
    for _, item in ipairs(receipt.items) do
        if not item.ok then failed = failed + 1 end
    end
    return string.format("下发 %d 台，失败 %d 台", #receipt.items, failed)
end
return actuator
