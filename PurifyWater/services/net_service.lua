-- 无线广播服务：每 10 秒编码一次只读快照，并按块逐个发送。
local CONFIG = require("shared.config")
local clock = require("services.clock")
local log = require("services.log")
local models = require("shared.models")
local settings = require("services.settings_store")
local state = require("services.state")
local device = require("hardware.device")

local service = {}
local source = nil
local due = 0
local modem = nil
local pending = nil
local frame = 0
local lastProblem = nil

local INTERVAL = CONFIG.NET.INTERVAL or 10
local PORT = CONFIG.NET.PORT or 4096
local CHUNK = CONFIG.NET.CHUNK or 4000

function service.setSource(fn)
    source = fn
end

local function setAvailable(value)
    local data = state.get()
    value = value == true
    if data.net.available ~= value then
        data.net.available = value
        state.bump()
    end
end

function service.load(now)
    local data = state.get()
    data.net.enabled = data.settings.netEnabled == true
    data.net.strength = tonumber(data.settings.netStrength) or CONFIG.NET.STRENGTH_DEFAULT
    due = tonumber(now) or clock.uptime()
    pending, modem, frame, lastProblem = nil, nil, 0, nil
    setAvailable(false)
    return true
end

local function discover()
    local found, kind
    for address, componentKind in pairs(device.list()) do
        if componentKind == "modem" or componentKind == "tunnel" then
            found, kind = address, componentKind
            break
        end
    end
    modem = found
    setAvailable(found ~= nil)
    return found, kind
end

local function prepare(now)
    if not source then due = now + INTERVAL; return false end
    local text = models.encodeSnapshot(source())
    if type(text) ~= "string" or text == "" then due = now + INTERVAL; return false end
    frame = frame + 1
    state.get().net.frame = frame
    pending = { frame = frame, text = text, index = 1, total = math.max(1, math.ceil(#text / CHUNK)) }
    return true
end

local function fail(message)
    local text = tostring(message or "广播失败")
    if text ~= lastProblem then
        log.warn("无线广播失败：" .. text)
        lastProblem = text
    end
    pending = nil
    modem = nil
    setAvailable(false)
end

function service.step(now)
    local data = state.get()
    if not data.net.enabled then pending = nil end

    if pending then
        local first = (pending.index - 1) * CHUNK + 1
        local part = pending.text:sub(first, first + CHUNK - 1)
        local message = models.chunk(pending.frame, pending.index, pending.total, part)
        local ok, err, reason = device.invoke(modem, "broadcast", PORT, message)
        if ok == false or (ok == nil and reason) then
            fail(err or reason or "发送被拒绝")
            due = now + INTERVAL
            return false
        end

        pending.index = pending.index + 1
        if pending.index <= pending.total then return true end
        pending = nil
        lastProblem = nil
        due = now + INTERVAL
        return false
    end

    if now < due then return false end

    if not modem then
        local found = discover()
        if not found then
            due = now + INTERVAL
            return false
        end
    end

    if not data.net.enabled then
        due = now + INTERVAL
        return false
    end

    if not prepare(now) then return false end
    return true
end

function service.nextDue(now)
    if pending then return now end
    return due
end

function service.toggle()
    local data = state.get()
    local nextValue = data.settings.netEnabled ~= true
    local ok, err = settings.set("net_enabled", nextValue and "true" or "false")
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end

    data.settings.netEnabled = nextValue
    data.net.enabled = nextValue
    state.bump()
    due = clock.uptime()
    log.system("无线广播：" .. (nextValue and "开" or "关"))
    return true, ""
end

function service.handle(name)
    if name ~= "net_toggle" then return false end
    local ok, err = service.toggle()
    return true, ok, err
end

return service