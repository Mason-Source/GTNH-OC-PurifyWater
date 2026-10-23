--------------------------------------------------------------------------------
-- monitor.lua —— 镜像端入口（**纯显示 / 只读**：收快照 -> 复用主端总览面板画出来）
--------------------------------------------------------------------------------
-- 【只读的结构性保证】
--   * 只 require shared/{config,models} 与 frontend/*；render.setup 不加载 viewmodel/input
--   * 不 require backend/*：本机组件除 GPU 与网卡外一概不碰
--   * 不注册定时任务、不写盘；输入只认退出键（Q / Ctrl+C）
--   * 只有【退出程序】按钮 + 本地视图动作（图表档位 / 状态详情）能点；其余按钮画禁用态

--     （不加载 input / backend：镜像端没有任何命令出口，点退出 = 退本程序）
-- 【用法】在有 modem/tunnel 的机器上：lua monitor.lua [端口]
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
    print("无法加载 core/locate.lua：cd 到应用根目录（含 core/ 的目录）后执行 lua monitor.lua")
    return
end

local appDir = locate.appDir(arg and arg[1], selfPath)
if appDir == "" then
    print("无法定位应用目录：cd 到应用根目录（含 core/ 的目录）后执行 lua monitor.lua")
    return
end
locate.injectPath(appDir)

local bootstrap = require("core.bootstrap")
bootstrap.clearModuleCache()

local CONFIG     = require("shared.config")
local models     = require("shared.models")
local computer   = require("computer")
local event      = require("event")
local component  = require("component")

local fstate     = require("frontend.state")
local theme      = require("frontend.theme")
local widgets    = require("frontend.widgets")
local layout     = require("frontend.layout")
local decorate   = require("frontend.decorate")
local viewinput  = require("frontend.viewinput")
local render     = require("frontend.render")

local PORT       = tonumber(({ ... })[1]) or CONFIG.NET.PORT

-- 镜像端：只读（交互画禁用态、不登记热区），固定在总览页、"全部"档
fstate.readOnly   = true
fstate.currentTab = "overview"
fstate.chartLevel = 0

-- 收到的分片：frames[帧号] = { parts = { [序号] = 文本 }, total = n, at = 时刻 }
local frames     = {}
-- 最近一份可用快照（形状同 api.read.*）与到达时刻
local snapshot, snapshotAt = nil, 0
-- 收到新快照才重画面板区
local dirty      = true

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
    for i = 1, slot.total do
        if slot.parts[i] == nil then return end
    end

    local text = {}
    for i = 1, slot.total do text[#text + 1] = slot.parts[i] end

    local payload, err = models.parseSnapshot(table.concat(text))
    if payload then
        if payload.version ~= models.SNAP_VERSION then
            payload.badVersion = true -- 屏上提示；能画的部分照画
        end
        -- 曲线是降频发（5 拍一次）：没有 C 行的这一拍沿用上一份，图表不会闪"数据采集中…"
        if not payload.history and snapshot and snapshot.history then
            payload.history = snapshot.history
        end
        snapshot, snapshotAt = payload, computer.uptime()
        dirty = true
    end

    -- 清掉旧帧（避免内存里攒一堆）
    for key in pairs(frames) do
        if computer.uptime() - frames[key].at > 10 then frames[key] = nil end
    end
end

--- 快照 -> 与主端 viewmodel 同形状的 data（补行 + 共用 decorate 做展示计算）
-- @return table|nil
local function buildView()
    if not snapshot then return nil end
    local data = {
        system   = snapshot.system or {},
        hardware = snapshot.hardware or {},
        power    = snapshot.power or {},
        plan     = snapshot.plan or { opened = {} },
        levels   = snapshot.levels or {},
        host     = snapshot.host or { switch = nil },
        logs     = snapshot.logs or {},
        net      = snapshot.net or { enabled = false, available = false },
        history  = snapshot.history
    }
    -- 曲线窗口固定按"全部"档（1 游戏日）：快照只带 1 日的 C 行（带宽取舍，见 ARCHITECTURE §5），
    --   镜像端切 Tn 档只换序列不换窗口 —— 比主端的 Tn（2 日）短，属既定差异，别"顺手修"。
    if data.history then data.historyDays = CONFIG.CHART.ALL_WINDOW_DAYS or 1 end
    decorate.apply(data)
    return data
end

--- 右上角一行：只读 / 版本 / 端口 / 新鲜度（只刷这一行，不重画面板）
local function drawMirrorLine()
    local W   = fstate.W
    local age = snapshot and (computer.uptime() - snapshotAt) or nil
    local text, color
    if snapshot and snapshot.badVersion then
        text  = string.format("镜像端 · 只读 ｜ 版本不一致（主机 v%s / 本机 v%s） ",
            tostring(snapshot.version), tostring(models.SNAP_VERSION))
        color = theme.COLORS.TEXT_RED
    elseif not snapshot then
        text, color = string.format("镜像端 · 只读 ｜ 端口 %d ｜ 等待数据… ", PORT), theme.COLORS.TEXT_RED
    elseif age > (CONFIG.NET.REFRESH or 2) * 3 then
        text, color = string.format("镜像端 · 只读 ｜ 端口 %d ｜ %.0f 秒前收到 ", PORT, age), theme.COLORS.TEXT_YELLOW
    else
        text, color = string.format("镜像端 · 只读 ｜ 端口 %d ｜ %.0f 秒前收到 ", PORT, age), theme.COLORS.TEXT_GREEN
    end
    local lineX = math.max(1, W - 40)
    widgets.clearArea(lineX, 1, W - lineX + 1, 1, theme.COLORS.BTN_BG)
    widgets.drawTextRight(1, W - 1, 1, text, color, theme.COLORS.BTN_BG)
end

--- 还没收到数据时的整屏提示
local function drawWaiting()
    fstate.gpu.setBackground(theme.COLORS.BG)
    fstate.gpu.fill(1, 1, fstate.W, fstate.H, " ")
    widgets.drawCenteredTip({ x = 1, y = 1, w = fstate.W, h = fstate.H },
        "还没收到数据：确认主机端【无线广播：开】，且两台机器的网卡在同一网络（按 Q 退出）",
        theme.COLORS.TEXT_YELLOW)
    widgets.clearArea(1, 1, fstate.W, 1, theme.COLORS.BTN_BG)
    drawMirrorLine()
end

--------------------------------------------------------------------------------
-- 启动
--------------------------------------------------------------------------------

local gpu = component.gpu
if not gpu then
    print("这台机器没有屏幕/GPU：镜像端必须有屏幕")
    return
end

-- 网卡或隧道（二者都有 open/receive；镜像端只收不发）
local modemAddress = component.list("modem")() or component.list("tunnel")()
if not modemAddress then
    print("这台机器没有网卡/隧道组件：镜像端需要 Network Card / Wireless Network Card / Linked Card")
    return
end
local openOk, openErr = pcall(component.invoke, modemAddress, "open", PORT)
if not openOk then
    print("监听端口失败：" .. tostring(openErr))
    return
end

render.setup()   -- gpu + 分辨率 + 布局（不接输入）

local lastLine = 0
while true do
    local ev   = { event.pull(0.5) }
    local name = ev[1]
    if name == "interrupted" then
        break
    elseif name == "modem_message" then
        -- 载荷 = (事件名, 网卡地址, 频道, 端口, 距离, 消息)
        local port, message = ev[4], ev[6]
        if port == PORT and type(message) == "string" then
            onMessage(message)
        end
    elseif name == "screen_resized" then
        layout.calculate()
        fstate.invalidateAll()
        dirty = true
    elseif name == "key_down" then
        local char, code = ev[3], ev[4]
        if char == 113 or code == 16 then break end
    elseif name == "touch" then
        -- 本机视图交互（都不发命令）：退出按钮 / 图表档位 / 状态详情
        local x, y = ev[3], ev[4]
        if type(x) == "number" and type(y) == "number" then
            if viewinput.quitButton(x, y) then
                break -- 退镜像端本程序（主控不受影响）
            elseif viewinput.statusArea(x, y) or viewinput.chartChip(x, y) then
                dirty = true -- 本地视图变了：下一帧按指纹重画对应面板
            end
        end
    end

    local now = computer.uptime()
    if not snapshot then
        if dirty then
            dirty    = false
            lastLine = now
            drawWaiting()
        end
    elseif dirty then
        dirty           = false
        lastLine        = now
        fstate.lastData = buildView()
        render.renderAll()
        drawMirrorLine()
    elseif (now - lastLine) > (CONFIG.NET.REFRESH or 2) then
        lastLine = now
        drawMirrorLine()
    end
end

render.restoreResolution()
bootstrap.releaseConsole()
print("镜像端已退出")
