-- component.invoke 唯一出口。
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

local function labelOf(method)
    return METHOD_LABELS[method] or tostring(method)
end

local function duration(ms)
    if ms >= 1000 then return string.format("%.2fs", ms / 1000) end
    return string.format("%.0fms", ms)
end

function device.list()
    local out = {}
    for address, kind in component.list() do out[address] = kind end
    return out
end

function device.typeOf(address)
    if not address then return nil end
    local ok, kind = pcall(component.type, address)
    if ok and type(kind) == "string" then return kind end
    return nil
end

function device.name(address)
    local value = device.invoke(address, "getName")
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

function device.coordinates(address)
    if not address then return nil, nil, nil end
    local ok, x, y, z = pcall(component.invoke, address, "getCoordinates")
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return x, y, z
    end
    return nil, nil, nil
end

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