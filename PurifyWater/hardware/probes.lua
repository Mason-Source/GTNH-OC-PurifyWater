-- T0-T8 单台机器原子读取。
local device = require("hardware.device")
local gt_infodata = require("hardware.gt_infodata")

local probes = {}

function probes.switch(address)
    local value, reason = device.invoke(address, "isWorkAllowed")
    if type(value) ~= "boolean" then return nil, reason or "switch is not boolean" end
    return value
end

function probes.active(address)
    local value, reason = device.invoke(address, "isMachineActive")
    if type(value) ~= "boolean" then return nil, reason or "active is not boolean" end
    return value
end

function probes.progress(address)
    local value, reason = device.invoke(address, "getWorkProgress")
    if type(value) ~= "number" then return nil, reason or "progress is not numeric" end
    return value
end

function probes.progressMax(address)
    local value, reason = device.invoke(address, "getWorkMaxProgress")
    if type(value) ~= "number" then return nil, reason or "max progress is not numeric" end
    return value
end

function probes.sensor(address)
    local lines, reason = device.invoke(address, "getSensorInformation")
    if type(lines) ~= "table" then return nil, reason or "sensor has no lines" end
    local common = gt_infodata.parse(lines)
    return {
        parallel = common.parallel,
        success = common.success,
        lines = lines,
    }
end

return probes
