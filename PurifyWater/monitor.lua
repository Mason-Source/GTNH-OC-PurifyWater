--------------------------------------------------------------------------------
-- monitor.lua   —— 镜像端入口（**纯显示，不调度、不写机器、不写盘**）
--------------------------------------------------------------------------------
-- 【职责】收无线快照 -> 解出新数据 -> 用同一套面板画出来（只读）
-- 【不做什么】
--   * 不注册任何定时任务（除了"多久没收到数据"这个本地判断）
--   * 不 require backend 里除 api 之外的东西（数据只从无线来，本机的组件一概不碰）
--   * 不写盘（连运行痕迹都不写：镜像端重装一次没有任何代价）
-- 【用法】在有网卡的电脑上：`lua monitor.lua [端口]`
--
-- 复用同一套面板：收到的快照被摆成与 api.read.* 相同的形状（models.parseSnapshot），
--   于是 viewmodel 与 panels 一行都不用改 —— 这是"快照格式只有一处定义"的回报。
--------------------------------------------------------------------------------

local selfPath   = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local selfDir    = selfPath:match("^(.*)[/\\][^/\\]*$")
local candidates = { "core/locate.lua", "./core/locate.lua", "PurifyWater/core/locate.lua" }
if selfDir then table.insert(candidates, selfDir .. "/core/locate.lua") end

local locate = nil
for _, path in ipairs(candidates) do
    local chunk = loadfile(path)
    if chunk then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" and type(mod.appDir) == "function" then
            locate = mod
            break
        end
    end
end
if not locate then
    print("无法装载 core/locate.lua：请先 cd 到应用根目录再执行 lua monitor.lua")
    return
end

local appDir = locate.appDir(arg and arg[1], selfPath)
if appDir == "" then
    print("无法定位应用目录：请先 cd 到应用根目录")
    return
end
locate.injectPath(appDir)

local bootstrap = require("core.bootstrap")
bootstrap.clearModuleCache()

local CONFIG               = require("shared.config")
local logs                 = require("shared.logs")
local models               = require("shared.models")
local computer             = require("computer")
local event                = require("event")
local component            = require("component")

local fstate               = require("frontend.state")
local theme                = require("frontend.theme")
local widgets              = require("frontend.widgets")

local PORT                 = tonumber(({ ... })[1]) or CONFIG.NET.PORT

-- 收到的分片：frames[帧号] = { parts = { [序号] = 文本 }, total = n, at = 时刻 }
local frames               = {}
-- 最近一份可用快照（形状同 api.read.*），以及它到达的时刻
local snapshot, snapshotAt = nil, 0
-- 【重绘模型】快照到达才算脏（重画全屏）；平时只刷右上角"多久前收到"那一行
local dirty                = true

--------------------------------------------------------------------------------
-- 收
--------------------------------------------------------------------------------

--- 处理一条无线消息
-- @param message string
local function onMessage(message)
    local frame, index, total, part = models.chunk(message)
    if not frame or not index or not total then return end
    if index > 64 or total > 64 or index > total then return end

    local slot = frames[frame]
    if not slot then
        slot = { parts = {}, total = total, at = computer.uptime() }
        frames[frame] = slot
    end
    slot.parts[index] = part or ""

    -- 收齐了？
    local count = 0
    for i = 1, slot.total do
        if slot.parts[i] == nil then return end
        count = count + 1
    end
    if count < slot.total then return end

    local text = {}
    for i = 1, slot.total do text[#text + 1] = slot.parts[i] end

    local payload, err = models.parseSnapshot(table.concat(text))
    if payload then
        snapshot, snapshotAt = payload, computer.uptime()
        dirty = true
    else
        logs.debug("[调试] 快照解析失败：" .. tostring(err))
    end

    -- 清掉旧帧（避免内存里攒一堆）
    for key in pairs(frames) do
        if computer.uptime() - frames[key].at > 10 then frames[key] = nil end
    end
end

--------------------------------------------------------------------------------
-- 画
--------------------------------------------------------------------------------

--- 把快照摆成 viewmodel 期望的形状并对齐字段
-- 【注意】镜像端不做任何计算，只把收到的数字排成行
-- @return table|nil
local function buildView()
    if not snapshot then return nil end
    local data = {
        system = snapshot.system or {},
        hardware = snapshot.hardware or {},
        power = snapshot.power or {},
        plan = snapshot.plan or { opened = {} },
        levels = snapshot.levels or {},
        host = snapshot.host or { switch = nil }
    }
    data.systemText, data.systemColor = theme.systemStatus(data.system, data.hardware)
    data.openedText = (#data.plan.opened == 0) and "全关"
        or ("开 " .. table.concat(data.plan.opened, "/"))
    data.powerUsedText = tostring(data.power.used or 0)
    data.powerAllText = tostring(data.power.all or 0)
    for level = 1, 8 do
        local row = data.levels[level] or { level = level, label = "T" .. level, deployed = 0, rule = {} }
        row.label = row.label or ("T" .. level)
        row.deployed = row.deployed or 0
        row.rule = row.rule or { threshold = 0, enabled = false }
        row.waterText = (row.water == nil) and "-" or tostring(row.water)
        row.thresholdText = tostring(row.rule.threshold or 0)
        row.switchText = (row.deployed == 0) and "未部署"
            or ((row.switch == nil) and "读不到" or (row.switch and "开" or "关"))
        row.running = (row.deployed > 0) and ((row.active or 0) > 0) or false
        row.verdict = (row.forced and "强制开") or (row.openable and "开" or "关")
        row.reasonText = row.reason or "-"
    end
    return data
end

--- 顶部两行：标题 + 端口/新鲜度（只刷这一部分时不重画全屏）
local function drawHeader()
    local W = fstate.W
    widgets.drawText(2, 1, "净化水线 v3 · 镜像端（只读）", theme.COLORS.TEXT_CYAN)
    widgets.drawTextRight(1, W - 1, 1, string.format("端口 %d ｜ %s ", PORT,
            snapshot and string.format("%.0f 秒前收到", computer.uptime() - snapshotAt) or "等待数据…"),
        snapshot and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_RED)
end

--- 画一屏（镜像端只画两块：总览表 + 底部一行连接状态）
local function draw()
    local W, H = fstate.gpu.getResolution()
    fstate.W, fstate.H = W, H
    fstate.gpu.setBackground(theme.COLORS.BG)
    fstate.gpu.fill(1, 1, W, H, " ")

    local data = buildView()
    drawHeader()

    if not data then
        widgets.drawCenteredTip({ x = 1, y = 1, w = W, h = H },
            "还没收到数据：确认控制端【无线广播:开】且两块网卡在同频道", theme.COLORS.TEXT_YELLOW)
        return
    end

    widgets.drawText(2, 2, data.systemText, data.systemColor)
    widgets.drawText(2, 3, string.format("功率 %s / %s EU/t ｜ 方案：%s",
        data.powerUsedText, data.powerAllText, data.openedText), theme.COLORS.TEXT_YELLOW)
    -- 主机就是一个总开关：开=允许各级水厂跑 / 关=禁止（不再有"三态"那套推测）
    local hostSwitch = data.host.switch
    local hostText   = (hostSwitch == nil) and "读不到" or (hostSwitch and "开" or "关")
    widgets.drawText(2, 4, string.format("主机总开关：%s ｜ ME接口：%s ｜ 硬件：主机 %d / 单元 %d / 能量仓 %d",
            hostText, data.hardware.me and "已连接" or "未连接",
            data.hardware.host or 0, data.hardware.units or 0, data.hardware.energy or 0),
        (hostSwitch == false) and theme.COLORS.TEXT_RED or theme.COLORS.TEXT)

    widgets.drawText(2, 6, "级   开关   运行   水量            阈值            判定     理由",
        theme.COLORS.TEXT_DISABLED)
    for level = 1, 8 do
        local row = data.levels[level]
        widgets.drawText(2, 6 + level, string.format("T%d  %-6s %-6s %-15s %-15s %-8s %s",
                level, row.switchText, row.running and "运行" or "停",
                row.waterText, row.thresholdText, row.verdict, tostring(row.reasonText)),
            row.running and theme.COLORS.TEXT or theme.COLORS.TEXT_DISABLED)
    end
end

--------------------------------------------------------------------------------
-- 主循环
--------------------------------------------------------------------------------

local gpu = component.gpu
if not gpu then
    print("这台机器没有屏幕/GPU：镜像端必须有屏幕")
    return
end
fstate.gpu = gpu

-- 网卡或隧道（隧道也有 open/send/receive）
local modemAddress = component.list("modem")() or component.list("tunnel")()
if not modemAddress then
    print("这台机器没有网卡/隧道组件：镜像端必须有网卡")
    return
end
local openOk, openErr = pcall(component.invoke, modemAddress, "open", PORT)
if not openOk then
    print("监听端口失败：" .. tostring(openErr))
    return
end

logs.system(string.format("镜像端启动：端口 %d（Ctrl+C / Q 退出）", PORT))
local lastDraw = 0

while true do
    local ev = { event.pull(0.5) }
    local name = ev[1]
    if name == "interrupted" then
        break
    elseif name == "modem_message" then
        -- 载荷 = (事件名, 网卡地址, 频道, 端口, 距离, 消息)
        local port, message = ev[4], ev[6]
        if port == PORT and type(message) == "string" then
            onMessage(message)
        end
    elseif name == "key_down" then
        local char, code = ev[3], ev[4]
        if char == 113 or code == 16 then break end
    end

    -- 快照到了才重画全屏；否则每 CONFIG.NET.REFRESH 秒只刷一次顶部状态行
    local now = computer.uptime()
    if dirty then
        dirty    = false
        lastDraw = now
        draw()
    elseif (now - lastDraw) > (CONFIG.NET.REFRESH or 2) then
        lastDraw = now
        drawHeader()
    end
end

-- 【先交还屏幕】镜像端也是直接画在 gpu 上的：刷黑 + 光标回左上，退出信息才看得清
bootstrap.releaseConsole()
print("镜像端已退出")
