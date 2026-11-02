--------------------------------------------------------------------------------
-- PurifyWater/services/control.lua
--
-- 定位：系统会话与调度门控状态。
-- 功能：维护运行、停止、等待用户和启动原因等 control 字段，并提供可启动条件检查。
-- 边界：是 control 数据的唯一写者；不读取观测、不访问组件。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local facts = require("services.facts")

local control = {}

local function ensure(data)
    data.control = data.control or {}
    data.control.awaiting = data.control.awaiting == true
end

--- 复制当前建议并行，作为本次运行的变化判定基线。
local function baselineOf(data)
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = math.floor(tonumber((data.plan.suggest or {})[level]) or 0)
    end
    return out
end

--- 检查硬件、水位和主机状态是否满足启动条件。
---@return string status ready/pending/error/invalid。
---@return string|nil reason 非 ready 状态的原因。
function control.canStart(data)
    local hardwareStatus, hardwareReason = facts.status(data.facts.hardware)
    if hardwareStatus == "pending" then return "pending", "正在完成首轮硬件扫描" end
    if hardwareStatus == "error" then return "error", "硬件观测失败：" .. tostring(hardwareReason) end

    local hardware = data.facts.hardware
    if #(hardware.missing or {}) > 0 then
        return "invalid", "硬件缺失：" .. table.concat(hardware.missing or {}, "、")
    end

    if data.power.observedAt == nil then
        if data.power.error then
            return "error", "能源观测失败：" .. tostring(data.power.error)
        end
        return "pending", "正在读取能源仓功率"
    end

    local waterStatus, waterReason = facts.status(data.facts.water)
    if waterStatus == "pending" then return "pending", "正在等待首轮水位观测" end
    if waterStatus == "error" then return "error", "水位观测失败：" .. tostring(waterReason) end

    local hostStatus, hostReason = facts.status(data.facts.host.switch)
    if hostStatus == "pending" then return "pending", "正在等待主机开关观测" end
    if hostStatus == "error" then return "error", "主机开关观测失败：" .. tostring(hostReason) end
    if data.facts.host.switch.value == false then return "invalid", "净水主机未开机" end
    return "ready"
end

--- 判断当前会话是否处于运行状态。
function control.isRunning(data)
    return data.control and data.control.session == "running"
end

--- 判断当前会话是否在等待用户处理。
function control.isAwaiting(data)
    return data.control and data.control.awaiting == true
end

--- 把会话切换到运行态并记录启动原因与建议基线。
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

--- 把会话切换到停止态并记录停机原因。
function control.stop(data, reason)
    ensure(data)
    data.control.session = "stopped"
    data.control.awaiting = false
    data.control.awaitingReason = nil
    data.control.stopReason = tostring(reason or "手动")
    data.control.suggestBaseline = nil
end

--- 暂停会话并要求用户处理异常。
function control.awaitUser(data, reason)
    ensure(data)
    data.control.session = "stopped"
    data.control.awaiting = true
    data.control.awaitingReason = tostring(reason or "等待处理")
    data.control.stopReason = data.control.awaitingReason
    data.control.suggestBaseline = nil
end

return control