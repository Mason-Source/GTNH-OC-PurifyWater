--------------------------------------------------------------------------------
-- main.lua   —— 控制端入口（界面 + 调度）
--------------------------------------------------------------------------------
-- 【启动顺序（规范，加东西都按这个顺序）】
--   ① 定位应用目录并注入 require 路径（此时还不能 require 工程模块）
--   ② 清旧模块缓存 + 注入数据根目录 + 写运行痕迹
--      （**清完缓存必须重新 require 一次 bootstrap**：否则版本号来自缓存里的旧 constants，见下）
--   ③ 注册定时任务（T1-T7）+ 读回阈值与历史 + 订阅事件与退出语义
--   ④ 注入广播快照来源 + 注册 T7 + 前端 boot + 进入主循环（每帧 = 界面一帧）
--   ⑤ 收尾：停机 + 强制存盘 + 写退出痕迹
--
-- 【前端在这一步接管了屏幕】面板见 frontend/panels/*；
--   数据只经 backend/api；命令只经 frontend/input -> api.do。
--------------------------------------------------------------------------------

-- ① 先把"定位器"本身装进来（全工程唯一一份目录定位实现）
local selfPath   = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local selfDir    = selfPath:match("^(.*)[/\\][^/\\]*$")
local candidates = { "core/locate.lua", "./core/locate.lua", "PurifyWater/core/locate.lua" }
if selfDir then table.insert(candidates, selfDir .. "/core/locate.lua") end

local locate, locateErr = nil, nil
for _, path in ipairs(candidates) do
    local chunk = loadfile(path)
    if chunk then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" and type(mod.appDir) == "function" then
            locate = mod
            break
        end
        if not ok then locateErr = tostring(mod) end
    end
end
if not locate then
    print("无法加载 core/locate.lua（" .. tostring(locateErr or "文件不存在") .. "）")
    print("用法：cd 到应用根目录（含 core/ 的目录）后执行 lua main.lua")
    return
end

local appDir = locate.appDir(arg and arg[1], selfPath)
if appDir == "" then
    print("无法定位应用目录：cd 到应用根目录（含 core/ 的目录）后执行 lua main.lua")
    return
end
locate.injectPath(appDir)

-- ② 卫生工作
-- OpenOS 把模块留在 package.loaded，热更新后首次重跑仍是旧 bootstrap；
-- 入口自身总是新的，故先借旧 bootstrap 清缓存，再重新 require 一份。
local bootstrap = require("core.bootstrap") -- 可能来自缓存：这一步只借它的"清缓存"能力
bootstrap.clearModuleCache()
bootstrap       = require("core.bootstrap") -- 重新装：版本号从这一份起才是新文件的

-- 入口先接管屏幕：模块解析在 OpenOS 上需要数秒，不能让用户一直看着旧终端。
local bootGpu = nil
local bootUnicode = nil
do
    local ok, component = pcall(require, "component")
    if ok and type(component) == "table" then bootGpu = component.gpu end
    local okUnicode, unicode = pcall(require, "unicode")
    if okUnicode then bootUnicode = unicode end
end

local function bootWidth(text)
    if bootUnicode and type(bootUnicode.wlen) == "function" then
        local ok, width = pcall(bootUnicode.wlen, text)
        if ok and type(width) == "number" then return width end
    end
    return #text
end

local function bootStatus(text)
    if not bootGpu then return end
    local ok, w, h = pcall(bootGpu.getResolution)
    if not ok or type(w) ~= "number" or type(h) ~= "number" then return end
    local mid    = math.max(1, math.floor(h / 2))
    local titleY = math.max(1, mid - 1)
    local textY  = math.min(h, mid + 1)
    local title  = "PurifyWater " .. bootstrap.version()
    local titleX = math.max(1, math.floor((w - bootWidth(title)) / 2) + 1)
    local textX  = math.max(1, math.floor((w - bootWidth(text)) / 2) + 1)
    pcall(bootGpu.setBackground, 0x000000)
    pcall(bootGpu.setForeground, 0xFFFFFF)
    pcall(bootGpu.fill, 1, 1, w, h, " ")
    pcall(bootGpu.setForeground, 0x66CCFF)
    pcall(bootGpu.set, titleX, titleY, title)
    pcall(bootGpu.setForeground, 0xAAAAAA)
    pcall(bootGpu.set, textX, textY, text)
end

bootStatus("正在加载共享模块…")

local CONFIG        = require("shared.config")
local constants     = require("shared.constants")
local logs          = require("shared.logs")
local state         = require("shared.state")
local utils         = require("shared.utils")
local models        = require("shared.models")
local runtime       = require("core.runtime")
bootStatus("正在加载后端模块…")

local files         = require("backend.store.files")
local settings      = require("backend.store.settings")
local trace         = require("backend.store.trace")
local log_file      = require("backend.store.log_file")
local history       = require("backend.store.history")
local levels_config = require("backend.store.levels_config")
local rates_config  = require("backend.store.rates_config")
local learning      = require("backend.domain.learning")
local jobs          = require("backend.jobs")
local handlers      = require("backend.handlers")
local api           = require("backend.api")
local power         = require("backend.domain.power")
local net           = require("backend.hardware.net")
local netApp        = require("backend.app.net")
local system        = require("backend.app.system")
local autostart     = require("backend.app.autostart")
local mode          = require("backend.domain.mode")
local thresholdMode = require("backend.domain.modes.threshold")
local rateMode      = require("backend.domain.modes.rate")
local produce       = require("backend.domain.produce")
local produceT3     = require("backend.domain.produce.t3")
local produceT4     = require("backend.domain.produce.t4")
local produceT5     = require("backend.domain.produce.t5")
local produceT6     = require("backend.domain.produce.t6")
local produceT7     = require("backend.domain.produce.t7")
local produceT8     = require("backend.domain.produce.t8")
bootStatus("正在加载前端模块…")
local render        = require("frontend.render")
bootStatus("正在初始化硬件与配置…")

files.setRoot(appDir) -- 数据文件（配置里的相对名）都相对应用目录解析

-- 【调度模式先装再用】注册内置模式，再按 settings 里的 mode 选当前模式（未知值告警回退阈值）。
--   必须早于任何 suggest()/evaluate()/audit() 调用 —— 也就是 jobs.register() 与 system.auditThresholds() 之前。
local bootSettings = settings.load() or {}
mode.register("threshold", thresholdMode)
mode.register("rate", rateMode)
if mode.has(bootSettings.mode) then
    state.write.setMode(bootSettings.mode)
else
    state.write.setMode("threshold")
    if bootSettings.mode ~= nil and bootSettings.mode ~= "" then
        logs.warn("未知调度模式 " .. tostring(bootSettings.mode) .. "，已回退阈值调度")
    end
end
state.write.setEnforce(models.bool(bootSettings.enforce_threshold, true))

-- 【制作自动化方法】等级强挂钩：加新级 = 新文件 + 这里一行
produce.register(constants.T3_LEVEL, produceT3)
produce.register(constants.T4_LEVEL, produceT4)
produce.register(constants.T5_LEVEL, produceT5)
produce.register(constants.T6_LEVEL, produceT6)
produce.register(constants.T7_LEVEL, produceT7)
produce.register(constants.T8_LEVEL, produceT8)

-- 能源仓利用因子（%）：可用功率 = 折算最大功率 × 因子；缺键/非法回落默认，并在首次启动补写一行
local factor = tonumber(bootSettings.energy_factor)
if not factor or factor ~= math.floor(factor)
    or factor < CONFIG.ENERGY.FACTOR_MIN or factor > CONFIG.ENERGY.FACTOR_MAX then
    factor = CONFIG.ENERGY.FACTOR_DEFAULT
end
state.write.setEnergyFactor(factor)
if bootSettings[CONFIG.ENERGY.FACTOR_KEY] == nil then
    settings.set(CONFIG.ENERGY.FACTOR_KEY, factor)
end

-- 速率配置（权重 + 回流 + T6 双锂 + T7 增产）：缺键补默认并落盘；必须早于任何 suggest()/evaluate()/audit()
rates_config.load()

trace.start(appDir, bootstrap.version())

logs.system(bootstrap.versionLine())
logs.system("调度模式：" .. mode.labelOf(state.read.mode()))

-- ③ 任务、数据、事件
jobs.register()

-- 注册后已各跑一次（T1 拿到功率、T2 拿到水位），此时读盘才有意义
levels_config.load()
history.load()
power.refresh()

handlers.subscribe()

-- 【首轮建议】由 jobs.register() 的首轮观测发布（台数 0→N 会触发），这里不重复发布
system.auditThresholds()

runtime.discardStaleInterrupts() -- 先丢掉上一个进程残留的 interrupted
runtime.bindQuitKeys()

-- 【开机默认值】运行模式是**永久配置**：存过就用存的，没存过才用 config 默认
-- （其余界面开关如无线广播仍只活在内存里，重启回到 config）
local savedSettings = settings.load()
if savedSettings and (savedSettings.priority == "high" or savedSettings.priority == "low") then
    state.write.setPriority(savedSettings.priority)
    logs.system(string.format("运行模式：%s（来自上次保存）",
        savedSettings.priority == "high" and "高级水优先" or "低级水优先"))
else
    state.write.setPriority(CONFIG.SYSTEM.PRIORITY_DEFAULT or "low")
end
-- 开机自启：真源在 $HOME/.shrc（勾选与否 = 那段标记块在不在）；这里只读回状态 + 按需写一行日志
autostart.refresh()

-- 无线广播：开关与范围都存 settings.txt（缺键首启补写默认值）；重启保持上次设置
netApp.loadSettings(savedSettings)

-- ④ 广播（T7）：快照来源由这里注入，避免 net 反过来 require api 造成环依赖
if net.register() then
    net.setSource(api.snapshot)
end
bootStatus("正在准备界面…")

render.boot()
logs.system("界面已就绪")

-- 无人值守机房：想让程序一启动就自动开调度，把 CONFIG.SYSTEM.START_ON_BOOT 改成 true
if CONFIG.SYSTEM.START_ON_BOOT then
    system.start("开机自启")
end

runtime.run(render.frame)

-- ⑤ 收尾：停机 + 存盘 + 痕迹
-- 【先还原屏幕】render.boot 可能按配置改过分辨率（放大字体），退出前原样还回去
-- 【再刷干净】退出信息不能压在界面残影上（见 bootstrap.releaseConsole）；
--   放在这里而不是 `print` 前：收尾里任何一步出错，报错也落在干净屏上。
do
    render.restoreResolution()
    bootstrap.releaseConsole()
    local learnedCount = learning.count()
    if state.read.running() then
        system.stop("程序退出")
    end
    local okHistory, historyNote = history.save()
    if not okHistory then logs.warn(tostring(historyNote)) end

    log_file.flush() -- 内存里还没落盘的日志补上（正常退出不会丢；崩溃最多丢半分钟）
    local j = jobs.last()
    trace.stop(runtime.quitReason(), string.format(
        "运行 %.0f 秒，硬件扫描 %d 次，水位 %s，总功率 %s，本次学习并行 %d 级，历史 %d 点",
        jobs.elapsed(), j.scanCount,
        j.fluidOk and "读取成功" or ("读取失败(" .. tostring(j.fluidErr) .. ")"),
        utils.formatNumber(j.powerBefore or 0), learnedCount,
        #state.read.chart().points))
end
print("已退出：" .. tostring(runtime.quitReason() or "未说明"))
print("运行痕迹：" .. tostring(trace.path()))
if state.read.autostart() then
    print("开机自启已开启：下次开机自动运行；重新运行：lua " .. appDir .. "/main.lua")
end
