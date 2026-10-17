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
local bootstrap = require("core.bootstrap") 
local removed   = bootstrap.clearModuleCache()
bootstrap       = require("core.bootstrap") 
bootstrap.applyArgs({ ... })
local memwatch, bootFree, bootTotal = nil, nil, nil
if require("shared.logs").isDebug() then
    bootFree  = require("computer").freeMemory()
    bootTotal = require("computer").totalMemory()
    memwatch  = require("backend.debug.memwatch") 
end
local CONFIG        = require("shared.config")
local constants     = require("shared.constants")
local logs          = require("shared.logs")
local state         = require("shared.state")
local utils         = require("shared.utils")
local models        = require("shared.models")
local runtime       = require("core.runtime")
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
local produceT7     = require("backend.domain.produce.t7")
local render        = require("frontend.render")
files.setRoot(appDir)
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
produce.register(constants.T3_LEVEL, produceT3)
produce.register(constants.T4_LEVEL, produceT4)
produce.register(constants.T7_LEVEL, produceT7)
local factor = tonumber(bootSettings.energy_factor)
if not factor or factor ~= math.floor(factor)
    or factor < CONFIG.ENERGY.FACTOR_MIN or factor > CONFIG.ENERGY.FACTOR_MAX then
    factor = CONFIG.ENERGY.FACTOR_DEFAULT
end
state.write.setEnergyFactor(factor)
if bootSettings[CONFIG.ENERGY.FACTOR_KEY] == nil then
    settings.set(CONFIG.ENERGY.FACTOR_KEY, factor)
end
rates_config.load()
trace.start(appDir, bootstrap.version())
if memwatch then memwatch.traceBoot(bootFree, bootTotal) end
logs.system(bootstrap.versionLine())
logs.system("调度模式：" .. mode.labelOf(state.read.mode()))
logs.debug("应用目录 " .. appDir
    .. (removed > 0 and ("（已清掉 " .. removed .. " 个旧模块缓存）") or ""))
local taskCount = jobs.register()
logs.debug(string.format("已注册 %d 个定时任务；日志级别 = %s", taskCount, logs.getLevel()))
local _, ruleText             = levels_config.load()
local gotHistory, historyText = history.load()
power.refresh()
logs.debug(tostring(ruleText))
logs.debug(tostring(historyText))
local subCount = handlers.subscribe()
logs.debug(string.format("已订阅 %d 类事件", subCount))
system.auditThresholds()
runtime.discardStaleInterrupts()
runtime.bindQuitKeys()
local savedSettings = settings.load()
if savedSettings and (savedSettings.priority == "high" or savedSettings.priority == "low") then
    state.write.setPriority(savedSettings.priority)
    logs.system(string.format("运行模式：%s（来自上次保存）",
        savedSettings.priority == "high" and "高级水优先" or "低级水优先"))
else
    state.write.setPriority(CONFIG.SYSTEM.PRIORITY_DEFAULT or "low")
end
autostart.refresh()
netApp.loadSettings(savedSettings)
if net.register() then
    net.setSource(api.snapshot)
    logs.debug(string.format("广播任务已注册（当前 %s）",
        state.read.net().enabled and "开" or "关"))
end
render.boot()
logs.system("界面已就绪")
if CONFIG.SYSTEM.START_ON_BOOT then
    system.start("开机自启")
end
runtime.run(render.frame)
do
    render.restoreResolution()
    bootstrap.releaseConsole()
    local learnedCount = learning.count()
    if state.read.running() then
        system.stop("程序退出")
    end
    local okHistory, historyNote = history.save()
    if not okHistory then logs.warn(tostring(historyNote)) end
    if memwatch then memwatch.watch(jobs.elapsed()) end
    log_file.flush()
    local j       = jobs.last()
    local memText = memwatch and memwatch.summary()
    trace.stop(runtime.quitReason(), string.format(
        "运行 %.0f 秒，硬件扫描 %d 次，水位 %s，总功率 %s，本次学习并行 %d 级，历史 %d 点%s",
        jobs.elapsed(), j.scanCount,
        j.fluidOk and "读取成功" or ("读取失败(" .. tostring(j.fluidErr) .. ")"),
        utils.formatNumber(j.powerBefore or 0), learnedCount,
        #state.read.chart().points,
        memText and ("，内存 " .. memText) or ""))
end
print("已退出：" .. tostring(runtime.quitReason() or "未说明"))
print("运行痕迹：" .. tostring(trace.path()))
if state.read.autostart() then
    print("开机自启已开启：下次开机自动运行；重新运行：lua " .. appDir .. "/main.lua")
end
