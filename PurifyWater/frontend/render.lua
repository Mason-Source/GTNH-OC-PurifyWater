--------------------------------------------------------------------------------
-- frontend/render.lua
--------------------------------------------------------------------------------
-- 【职责】前端入口：boot（取 gpu + 可选改分辨率 + 算布局 + 订阅输入）+ frame（每帧：取数据 -> 按指纹重绘）
-- 【不做什么】不取业务数据的**判断**（数据经 viewmodel，命令经 input -> api.exec）
-- 【依赖】frontend/{state,theme,layout,viewmodel,input,panels/*}、core/scheduler、shared/config
-- 【被谁用】main.lua（T8 = runtime 的帧钩子，每帧调 `render.frame()`）；monitor.lua 用 restore/boot 的一部分
--
-- 【重绘模型：谁变谁重绘】
--   每个面板一个**指纹**（把影响它显示的所有字段拼成字符串），指纹没变就不画。
--   * 数据变了 -> 指纹自然变 -> 只重画那个面板；
--   * 命令执行后 -> viewmodel 过期重建（input 里调 `vm.expire()`），下一帧按指纹局部重绘；
--   * **只有**切页 / 改分辨率 / 换字体才整屏清屏重画（那才是"版面结构变了"）。
--------------------------------------------------------------------------------

local fstate        = require("frontend.state")
local theme         = require("frontend.theme")
local layout        = require("frontend.layout")
local viewmodel     = require("frontend.viewmodel")
local input         = require("frontend.input")
local CONFIG        = require("shared.config")
local logs          = require("shared.logs")
local scheduler     = require("core.scheduler")

local tabBarPanel   = require("frontend.panels.tabbar")
local controlPanel  = require("frontend.panels.control")
local statusPanel   = require("frontend.panels.status")
local chartPanel    = require("frontend.panels.chart")
local logPanel      = require("frontend.panels.log")
local configPanel   = require("frontend.panels.config")
local editlinePanel = require("frontend.panels.editline")
local keypadPanel   = require("frontend.panels.keypad")

local render        = {}

-- 面板注册表：一个面板 = 一个"画" + 一个"指纹"
-- 【详情不在这一层】单级详情是"净水状态面板换了个内容"（同一格位、同一矩形）：
--   切进/切出只让 status 的指纹变，于是**只重画这一块**。分发在 panels/status.lua 里。
local PANELS        = {
    tabBar   = { draw = tabBarPanel.draw, fingerprint = tabBarPanel.fingerprint },
    control  = { draw = controlPanel.draw, fingerprint = controlPanel.fingerprint },
    status   = { draw = statusPanel.draw, fingerprint = statusPanel.fingerprint },
    chart    = { draw = chartPanel.draw, fingerprint = chartPanel.fingerprint },
    log      = { draw = logPanel.draw, fingerprint = logPanel.fingerprint },
    config   = { draw = configPanel.draw, fingerprint = configPanel.fingerprint },
    editline = { draw = editlinePanel.draw, fingerprint = editlinePanel.fingerprint },
    keypad   = { draw = keypadPanel.draw, fingerprint = keypadPanel.fingerprint }
}

-- 每个页由哪些面板组成
-- 配置页分三块：列表 / 回显 / 键盘各管各的指纹 —— 敲键只重画回显那一行。
local TAB_PANELS    = {
    overview = { "tabBar", "control", "status", "chart", "log" },
    config   = { "tabBar", "config", "editline", "keypad" }
}

--------------------------------------------------------------------------------
-- 启动
--------------------------------------------------------------------------------

--- 按配置放大字体（**可选**）：OC 里字的大小只由字符分辨率决定
-- 配置里给了更小的格数（例如 100×32）就 setResolution，退出时原样还原；填 0 = 不动屏幕。
-- 不打日志：原来 [系统] 与 [界面] 各写一行分辨率，改完屏幕上一眼就看出来了。
function render.applyResolution()
    local gpu = fstate.gpu
    if not gpu then return end
    local w, h            = gpu.getResolution()
    fstate.baseResolution = { width = w, height = h }

    local targetW         = CONFIG.UI.RESOLUTION_WIDTH or 0
    local targetH         = CONFIG.UI.RESOLUTION_HEIGHT or 0
    if targetW > 0 or targetH > 0 then
        local wantW = (targetW > 0) and targetW or w
        local wantH = (targetH > 0) and targetH or h
        if wantW ~= w or wantH ~= h then
            local ok, err = pcall(gpu.setResolution, wantW, wantH)
            if not ok then
                logs.warn("改分辨率失败（屏幕/显卡不支持），保持原样：" .. tostring(err))
            end
        end
    end
end

--- 还原到程序启动前的分辨率（退出时由入口调用）
function render.restoreResolution()
    local base = fstate.baseResolution
    if not base or not fstate.gpu then return end
    local w, h = fstate.gpu.getResolution()
    if w ~= base.width or h ~= base.height then
        pcall(fstate.gpu.setResolution, base.width, base.height)
    end
end

--- 取 gpu、算布局、订阅输入事件
-- 只订阅 key_down / touch：别的外部事件（component_* 等）与界面无关
function render.boot()
    fstate.gpu = require("component").gpu
    render.applyResolution()
    layout.calculate()

    scheduler.on("key_down", function(payload) input.handle("key_down", payload) end)
    scheduler.on("touch", function(payload) input.handle("touch", payload) end)
    -- 分辨率变化：重算布局（否则面板会画到屏幕外）
    scheduler.on("screen_resized", function() layout.calculate() end)

    fstate.invalidateAll()
end

--------------------------------------------------------------------------------
-- 每帧
--------------------------------------------------------------------------------

--- 渲染一帧（只重画指纹变过的面板）
-- @param forceAll boolean|nil 强制全部重绘（切页 / 版面变化）
function render.renderAll(forceAll)
    local fps = fstate.render.fingerprints
    forceAll  = forceAll or fstate.render.forceAll

    if forceAll then
        fstate.gpu.setBackground(theme.COLORS.BG)
        fstate.gpu.fill(1, 1, fstate.W, fstate.H, " ")
        for name in pairs(fps) do fps[name] = nil end
        -- 子区域指纹一并清掉：屏幕已经空了，"以为画过了"就不对了
        fstate.clearSubs()
        -- 全量重绘等于"换了一页"：旧页面的热区必须丢掉，否则会点到看不见的东西
        fstate.clearHitboxes()
    end

    local data = fstate.lastData
    local list = TAB_PANELS[fstate.currentTab] or TAB_PANELS.overview
    for _, name in ipairs(list) do
        local panel = PANELS[name]
        if panel then
            local fp = panel.fingerprint(data)
            if forceAll or fps[name] ~= fp then
                panel.draw(data)
                fps[name] = fp
            end
        end
    end
    fstate.render.forceAll = false
end

--- 一帧：取数据 -> 重绘（谁变了画谁）
-- 取数据在前：指纹比较要用这一帧的数据，必须同帧一致
function render.frame()
    local data = viewmodel.build()
    input.attach(data)
    render.renderAll()
end

return render
