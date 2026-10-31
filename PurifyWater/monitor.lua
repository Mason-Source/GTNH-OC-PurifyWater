-- 镜像端入口：只收无线快照并显示 overview，不加载业务读写链。
local selfPath = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local selfDir = selfPath:match("^(.*)[/\\][^/\\]*$")
local locateChunk = assert(loadfile((selfDir or ".") .. "/core/locate.lua"), "cannot load core/locate.lua")
local locate = locateChunk()
local appDir = locate.appDir(arg and arg[1], selfPath)
if appDir == "" then
    print("无法定位应用目录（需要 core/bootstrap.lua）")
    return
end
locate.injectPath(appDir)

local bootstrap = require("core.bootstrap")
bootstrap.clearModuleCache()
bootstrap = require("core.bootstrap")

local CONFIG = require("shared.config")
local clock = require("services.clock")
local models = require("shared.models")
local event = require("event")
local component = require("component")
local app = require("frontend.app")

local PORT = tonumber(arg and arg[1]) or CONFIG.NET.PORT or 4096
local frames = {}
local snapshot = nil
local snapshotAt = 0
local dirty = true
local lastLine = 0
local lastError = nil
local quitting = false

app.setSnapshotReader(function() return snapshot end)
app.setActionHandler(function(name)
    if name == "quit" then
        quitting = true
        return true
    end
    return false
end)
assert(app.boot({ readOnly = true }), "frontend boot failed")

local function findModem()
    for address, kind in component.list() do
        if kind == "modem" or kind == "tunnel" then return address end
    end
end

local modemAddress = findModem()
if not modemAddress then
    print("这台机器没有网卡/隧道组件")
    return
end
local openOk, openErr = pcall(component.invoke, modemAddress, "open", PORT)
if not openOk then
    print("监听端口失败：" .. tostring(openErr))
    return
end

local function drawMirrorLine()
    local p = assert(app.painter, "painter missing")
    local width = app.viewport.width
    local age = snapshot and (clock.uptime() - snapshotAt) or nil
    local text, role
    if not snapshot then
        text, role = string.format("镜像端 · 只读 | 端口 %d | 等待数据", PORT), "warning"
    elseif age > (CONFIG.NET.STALE or 30) then
        text, role = string.format("镜像端 · 只读 | 端口 %d | %.0f秒前收到", PORT, age), "warning"
    else
        text, role = string.format("镜像端 · 只读 | 端口 %d | %.0f秒前收到 | %s",
            PORT, age, tostring(snapshot.version or "-")), "success"
    end
    local lineX = math.max(1, width - 45)
    local room = width - lineX + 1
    p:fill({ x = lineX, y = 1, w = room, h = 1 }, "surfaceAlt")
    p:textRight(lineX, 1, room, p:truncate(text, room), role, "surfaceAlt")
end

local function drawWaiting()
    local p = assert(app.painter, "painter missing")
    local width, height = app.viewport.width, app.viewport.height
    p:clear({ x = 1, y = 1, w = width, h = height })
    local message = lastError
        or "等待主控广播：确认无线广播已开启，且两台机器处于同一网络（Q 退出）"
    message = p:truncate(message, width - 2)
    p:text(math.max(2, math.floor((width - p:measure(message)) / 2)),
        math.floor(height / 2), message, lastError and "danger" or "warning", "canvas", width - 2)
    drawMirrorLine()
end

local function accept(message)
    local frame, index, total, part = models.parseChunk(message)
    if not frame or not index or not total then return false end
    if total < 1 or total > 64 or index < 1 or index > total then return false end

    local now = clock.uptime()
    for key, slot in pairs(frames) do
        if now - slot.at > 60 then frames[key] = nil end
    end
    local slot = frames[frame]
    if not slot then
        slot = { parts = {}, total = total, at = now }
        frames[frame] = slot
    end
    slot.parts[index] = part or ""
    for i = 1, total do if slot.parts[i] == nil then return false end end

    local parts = {}
    for i = 1, total do parts[#parts + 1] = slot.parts[i] end
    frames[frame] = nil
    local payload, err = models.decodeSnapshot(table.concat(parts))
    if not payload then
        lastError = tostring(err or "快照解析失败")
        dirty = true
        return false
    end

    snapshot, snapshotAt, lastError, dirty = payload, now, nil, true
    return true
end

while not quitting do
    local ev = { event.pull(0.5) }
    local name = ev[1]
    if name == "interrupted" then
        break
    elseif name == "key_down" then
        local char, code = ev[3], ev[4]
        if char == 113 or code == 16 then break end
        if app.handle(ev) then app.frameInput() end
    elseif name == "modem_message" then
        if ev[4] == PORT and type(ev[6]) == "string" then accept(ev[6]) end
    elseif name == "screen_resized" or name == "touch" then
        if name == "screen_resized" then dirty = true end
        if app.handle(ev) then app.frameInput() end
    end

    local now = clock.uptime()
    if snapshot then
        if dirty then
            dirty, lastLine = false, now
            app.frameData()
            drawMirrorLine()
        elseif now - lastLine >= (CONFIG.NET.REFRESH or 2) then
            lastLine = now
            drawMirrorLine()
        end
    elseif dirty then
        dirty, lastLine = false, now
        drawWaiting()
    end
end

app.restoreResolution()
bootstrap.releaseConsole()
print("镜像端已退出")