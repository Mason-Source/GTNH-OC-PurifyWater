local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local models    = require("shared.models")
local state     = require("shared.state")
local scheduler = require("core.scheduler")
local device    = require("backend.hardware.device")
local net       = {}
local source    = nil
local TASK      = "broadcast"
function net.setSource(fn)
    source = fn
end
function net.available()
    return device.net() ~= nil
end
function net.status()
    local st = state.read.net()
    return {
        available = net.available(),
        enabled = st.enabled == true,
        strength = state.read.netStrength()
    }
end
function net.setEnabled(on)
    local before      = state.read.net().enabled == true
    state.write.netSetEnabled(on == true)
    scheduler.setEnabled(TASK, state.read.net().enabled)
    local text = state.read.net().enabled
        and (net.available() and "无线广播：已开启" or "无线广播：已开启（网卡不在位，不发送）")
        or "无线广播：已关闭"
    if state.read.net().enabled ~= before then logs.system(text) end
    return text
end
function net.sendText(text)
    local address = device.net()
    if not address then return false, "无网卡/隧道组件" end
    local port      = CONFIG.NET.PORT
    local chunkSize = math.max(256, CONFIG.NET.CHUNK or 4000)
    local total     = math.max(1, math.ceil(#text / chunkSize))
    local frame     = (state.read.net().frame or 0) + 1
    state.write.netSetFrame(frame)
    for i = 1, total do
        local part      = text:sub((i - 1) * chunkSize + 1, i * chunkSize)
        local message   = table.concat({ "v3", frame, i, total, part }, "|")
        local sent, err, reason = device.invoke(address, "broadcast", port, message)
        if err then return false, "发送失败：" .. tostring(err) end
        if sent == false or (sent == nil and reason) then
            return false, "发送被拒：" .. tostring(reason or "端口/距离")
        end
    end
    return true, string.format("已广播 %d 片 / %d 字节", total, #text)
end
local strengthFor, strengthSent = nil, nil
local function pushStrength(address, value)
    if not address then return nil, "无卡" end
    if device.invoke(address, "isWireless") ~= true then return nil, "有线卡" end
    local applied, err = device.invoke(address, "setStrength", value)
    if err then return nil, tostring(err) end
    strengthFor, strengthSent = address, value
    return tonumber(applied) or value
end
local function syncStrength()
    local address = device.net()
    if not address then strengthFor, strengthSent = nil, nil return end
    local value = state.read.netStrength()
    if strengthFor == address and strengthSent == value then return end
    local applied, why = pushStrength(address, value)
    if not applied then
        strengthFor, strengthSent = address, value
        if why ~= "有线卡" then logs.warn("设置无线范围失败：" .. tostring(why)) end
        return
    end
    if applied ~= value then
        logs.system(string.format("无线范围 %d 超出卡上限，已按 %d 生效", value, applied))
    end
end
local tickCount = 0
function net.setStrength(value)
    return pushStrength(device.net(), value)
end
function net.tick()
    if state.read.net().enabled ~= true then return end
    if not source then return end
    if not net.available() then return end
    syncStrength()
    tickCount = tickCount + 1
    local payload, buildErr = source({ chart = (tickCount % 5 == 1) })
    if not payload then
        if not state.read.net().warned then
            state.write.netSetWarned(true)
            logs.warn("广播快照组装失败：" .. tostring(buildErr))
        end
        return
    end
    local ok, text = net.sendText(models.snapshot(payload))
    if not ok then
        if not state.read.net().warned then
            state.write.netSetWarned(true)
            logs.warn("广播失败：" .. tostring(text))
        end
        return
    end
    if state.read.net().warned then
        state.write.netSetWarned(nil)
        logs.system("广播已恢复")
    end
end
function net.register()
    return scheduler.every(TASK, CONFIG.INTERVAL.BROADCAST, net.tick,
        { enabled = state.read.net().enabled == true })
end
return net
