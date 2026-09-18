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
    local st = state.net
    return {
        available = net.available(),
        enabled = st.enabled == true
    }
end
function net.setEnabled(on)
    local before      = state.net.enabled == true
    state.net.enabled = on == true
    scheduler.setEnabled(TASK, state.net.enabled and net.available())
    local text = state.net.enabled
        and (net.available() and "无线广播：已开启" or "无线广播：已开启（但网卡不在位）")
        or "无线广播：已关闭"
    if state.net.enabled ~= before then logs.system(text) end
    return text
end
function net.toggle()
    local st = state.net
    return net.setEnabled(not (st.enabled == true))
end
function net.sendText(text)
    local address = device.net()
    if not address then return false, "无网卡/隧道组件" end
    local port      = CONFIG.NET.PORT
    local chunkSize = math.max(256, CONFIG.NET.CHUNK or 4000)
    local total     = math.max(1, math.ceil(#text / chunkSize))
    local frame     = (state.net.frame or 0) + 1
    state.net.frame = frame
    for i = 1, total do
        local part      = text:sub((i - 1) * chunkSize + 1, i * chunkSize)
        local message   = table.concat({ "v3", frame, i, total, part }, "|")
        local sent, err = device.invoke(address, "send", port, message, 0)
        if err then return false, "发送失败：" .. tostring(err) end
        if sent == false then return false, "发送被拒（端口/距离？）" end
    end
    return true, string.format("已广播 %d 片 / %d 字节", total, #text)
end
function net.tick()
    if state.net.enabled ~= true then return end
    if not source then return end
    local payload, buildErr = source()
    if not payload then
        if not state.net.warned then
            state.net.warned = true
            logs.warn("广播快照组装失败：" .. tostring(buildErr))
        end
        return
    end
    local ok, text = net.sendText(models.snapshot(payload))
    if not ok then
        if not state.net.warned then
            state.net.warned = true
            logs.warn("广播失败：" .. tostring(text))
        end
        return
    end
    if state.net.warned then
        state.net.warned = nil
        logs.system("广播已恢复")
    end
end
function net.register()
    return scheduler.every(TASK, CONFIG.INTERVAL.BROADCAST, net.tick,
        { enabled = state.net.enabled == true and net.available() })
end
return net
