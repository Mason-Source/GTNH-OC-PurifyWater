-- 会话与调度门控：control 数据的唯一写者，不碰组件、不读观测。
local constants = require("shared.constants")

local control = {}

local function ensure(data)
    data.control = data.control or {}
    data.control.awaiting = data.control.awaiting == true
end

local function baselineOf(data)
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = math.floor(tonumber((data.plan.suggest or {})[level]) or 0)
    end
    return out
end

function control.canStart(data)
    local hardware = data.facts.hardware
    if not hardware or hardware.value == nil then return false, "正在完成首轮硬件扫描" end
    if #(hardware.missing or {}) > 0 then
        return false, "硬件缺失：" .. table.concat(hardware.missing or {}, "、")
    end
    if not data.facts.water or data.facts.water.value == nil then
        return false, "正在等待首轮水位观测"
    end
    if data.facts.host.switch.value == false then return false, "净水主机未开机" end
    return true, nil
end

function control.isRunning(data)
    return data.control and data.control.session == "running"
end

function control.isAwaiting(data)
    return data.control and data.control.awaiting == true
end

function control.start(data, reason)
    ensure(data)
    data.control.session = "running"
    data.control.awaiting = false
    data.control.awaitingReason = nil
    data.control.stopReason = nil
    data.control.startReason = tostring(reason or "手动")
    data.control.suggestBaseline = baselineOf(data)
    return true
end

function control.stop(data, reason)
    ensure(data)
    data.control.session = "stopped"
    data.control.awaiting = false
    data.control.awaitingReason = nil
    data.control.stopReason = tostring(reason or "手动")
    data.control.suggestBaseline = nil
end

function control.awaitUser(data, reason)
    ensure(data)
    data.control.session = "stopped"
    data.control.awaiting = true
    data.control.awaitingReason = tostring(reason or "等待处理")
    data.control.stopReason = data.control.awaitingReason
    data.control.suggestBaseline = nil
end

return control