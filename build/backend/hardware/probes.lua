local device     = require("backend.hardware.device")
local gtInfodata = require("backend.hardware.gt_infodata")
local probes     = {}
function probes.switch(address)
    local value, err = device.invoke(address, "isWorkAllowed")
    if type(value) == "boolean" then return value, nil end
    return nil, err or ("开关读数不是布尔值：" .. tostring(value))
end
function probes.active(address)
    local value, err = device.invoke(address, "isMachineActive")
    if type(value) == "boolean" then return value, nil end
    return nil, err or ("活动读数不是布尔值：" .. tostring(value))
end
function probes.progress(address)
    local progress, err = device.invoke(address, "getWorkProgress")
    local maxProgress   = device.invoke(address, "getWorkMaxProgress")
    if type(progress) ~= "number" then return nil, nil, err or "无进度读数" end
    return progress, type(maxProgress) == "number" and maxProgress or nil, nil
end
function probes.sensor(address)
    local lines, err = device.invoke(address, "getSensorInformation")
    if type(lines) ~= "table" then return nil, err or "传感器无数据" end
    return gtInfodata.parse(lines), nil
end
return probes
