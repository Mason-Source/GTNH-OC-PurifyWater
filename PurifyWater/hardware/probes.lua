--------------------------------------------------------------------------------
-- PurifyWater/hardware/probes.lua
--
-- 定位：单台净水机器的原子观测封装。
-- 功能：读取开关、运行状态、进度、总进度和传感器信息，并统一校验返回类型。
-- 边界：每次只执行一个组件调用，不聚合等级结果，也不修改业务状态。
--------------------------------------------------------------------------------

local device = require("hardware.device")
local gt_infodata = require("hardware.gt_infodata")

local probes = {}

--- 读取机器允许运行开关，并要求布尔返回。
function probes.switch(address)
    local value, reason = device.invoke(address, "isWorkAllowed")
    if type(value) ~= "boolean" then return nil, reason or "switch is not boolean" end
    return value
end

--- 读取机器当前运行状态，并要求布尔返回。
function probes.active(address)
    local value, reason = device.invoke(address, "isMachineActive")
    if type(value) ~= "boolean" then return nil, reason or "active is not boolean" end
    return value
end

--- 读取当前周期进度。
function probes.progress(address)
    local value, reason = device.invoke(address, "getWorkProgress")
    if type(value) ~= "number" then return nil, reason or "progress is not numeric" end
    return value
end

--- 读取当前周期总进度。
function probes.progressMax(address)
    local value, reason = device.invoke(address, "getWorkMaxProgress")
    if type(value) ~= "number" then return nil, reason or "max progress is not numeric" end
    return value
end

--- 读取并解析机器传感器中的并行与成功率。
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
