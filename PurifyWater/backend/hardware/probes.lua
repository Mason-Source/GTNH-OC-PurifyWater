--------------------------------------------------------------------------------
-- backend/hardware/probes.lua
--------------------------------------------------------------------------------
-- 【职责】单台机器的原子读取：开关 `isWorkAllowed` / 活动 `isMachineActive` /
--         进度 `getWorkProgress` / 传感器 `getSensorInformation`（解析交给 gt_infodata）
-- 【不做什么】只读；不写 state（聚合在 jobs 的采集任务里做）；不下发任何指令
-- 【依赖】hardware/{device,gt_infodata}
-- 【被谁用】backend/jobs（T3）
--
-- 一律走 device.invoke（proxy 索引拿不到 gt_machine 方法）。
-- 读失败返回 nil + 错误文本，不隐式当 false。
--------------------------------------------------------------------------------

local device     = require("backend.hardware.device")
local gtInfodata = require("backend.hardware.gt_infodata")

local probes     = {}

--- 工作开关
-- @param address string 组件地址
-- @return boolean|nil, string|nil
function probes.switch(address)
    local value, err = device.invoke(address, "isWorkAllowed")
    if type(value) == "boolean" then return value, nil end
    return nil, err or ("开关读数不是布尔值：" .. tostring(value))
end

--- 是否在处理配方（空闲 ≠ 停机）
-- @param address string 组件地址
-- @return boolean|nil, string|nil
function probes.active(address)
    local value, err = device.invoke(address, "isMachineActive")
    if type(value) == "boolean" then return value, nil end
    return nil, err or ("活动读数不是布尔值：" .. tostring(value))
end

--- 运行进度（getWorkProgress/getWorkMaxProgress）
-- 只对主机调（周期同步）。用途：界面周期条、tracker 判周期边界。
-- @param address string 组件地址
-- @return number|nil progress
-- @return number|nil maxProgress
-- @return string|nil 错误说明
function probes.progress(address)
    local progress, err = device.invoke(address, "getWorkProgress")
    local maxProgress   = device.invoke(address, "getWorkMaxProgress")
    if type(progress) ~= "number" then return nil, nil, err or "无进度读数" end
    return progress, type(maxProgress) == "number" and maxProgress or nil, nil
end

--- 传感器信息（已解析）；只对在跑机器调用。
-- @param address string 组件地址
-- @return table|nil gt_infodata.parse() 的结果
-- @return string|nil 错误说明
function probes.sensor(address)
    local lines, err = device.invoke(address, "getSensorInformation")
    if type(lines) ~= "table" then return nil, err or "传感器无数据" end
    return gtInfodata.parse(lines), nil
end

return probes
