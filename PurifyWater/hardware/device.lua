--------------------------------------------------------------------------------
-- PurifyWater/hardware/device.lua
--
-- 定位：OC 组件的唯一调用出口。
-- 功能：列出组件、读取名称/类型/坐标，统一封装 component.invoke 的异常、耗时统计与失败原因。
-- 边界：业务模块不得直接 require component 调用设备；本层不解释业务语义。
--------------------------------------------------------------------------------

local component = require("component")
local clock = require("services.clock")
local log = require("services.log")
local util = require("shared.util")

local device = {}

local METHOD_LABELS = {
    getSensorInformation = "传感器读取",
    getFluidsInNetwork = "流体网络读取",
    getFluidInNetwork = "流体查询",
    getAllStacks = "物品槽读取",
    getFluidInTank = "流体罐读取",
    getFluidTransferRate = "转运速率读取",
    transferFluid = "流体转运",
    transferItem = "物品转运",
    broadcast = "无线广播",
    send = "无线发送",
    isWorkAllowed = "机器开关读取",
    setWorkAllowed = "机器开关下发",
    isMachineActive = "机器运行读取",
    getWorkProgress = "周期进度读取",
    getWorkMaxProgress = "周期总进度读取",
    getEUMaxStored = "能源存量读取",
    getCoordinates = "坐标读取",
    getName = "组件名称读取",
}

--- 返回组件方法的日志中文名。
local function labelOf(method)
    return METHOD_LABELS[method] or tostring(method)
end

--- 把毫秒耗时格式化为紧凑的 ms/s 文本。
local function duration(ms)
    if ms >= 1000 then return string.format("%.2fs", ms / 1000) end
    return string.format("%.0fms", ms)
end

--- 返回当前已连接组件的地址到类型映射。
function device.list()
    local out = {}
    for address, kind in component.list() do out[address] = kind end
    return out
end

--- 返回组件的 OC 类型名。
---@param address string|nil 组件地址。
---@return string|nil kind 组件类型。
---@return string|nil reason 失败原因。
function device.typeOf(address)
    if not address then return nil, "地址为空" end
    local ok, kind = pcall(component.type, address)
    if not ok then return nil, tostring(kind) end
    if type(kind) == "string" then return kind end
    return nil, "组件类型无效"
end

--- 读取组件名称。
---@param address string|nil 组件地址。
---@return string|nil name 组件名称。
---@return string|nil reason 失败原因。
function device.name(address)
    local value, reason = device.invoke(address, "getName")
    if type(value) == "string" and value ~= "" then return value end
    return nil, tostring(reason or "组件名称为空")
end

--- 读取组件坐标。
---@param address string|nil 组件地址。
---@return number|nil x
---@return number|nil y
---@return number|nil z
---@return string|nil reason 失败原因。
function device.coordinates(address)
    if not address then return nil, nil, nil, "地址为空" end
    local ok, x, y, z = pcall(component.invoke, address, "getCoordinates")
    if not ok then return nil, nil, nil, tostring(x) end
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return x, y, z
    end
    return nil, nil, nil, "组件坐标无效"
end

--- 调用组件方法，并统一处理异常、耗时告警和返回值。
function device.invoke(address, method, ...)
    if not address then return nil, "地址为空" end
    local started = clock.cpuTime()
    local ok, value, reason = pcall(component.invoke, address, method, ...)
    local elapsed = (clock.cpuTime() - started) * 1000
    local label = labelOf(method)
    local short = util.shortAddress(address)

    if not ok then
        log.error(string.format("%s失败：%s（%s）", label, tostring(value), short))
        return nil, value
    end

    if elapsed >= 1000 then
        log.warn(string.format("%s延迟 %s（%s）", label, duration(elapsed), short))
    elseif elapsed >= 250 then
        log.diag(string.format("%s %s（%s）", label, duration(elapsed), short))
    end
    return value, reason
end

return device