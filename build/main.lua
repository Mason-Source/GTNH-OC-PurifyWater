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
    print("无法装载 core/locate.lua（" .. tostring(locateErr or "文件不存在") .. "）")
    print("请先 cd 到应用根目录（含 core/ 的目录）再执行：lua main.lua")
    return
end
local appDir = locate.appDir(arg and arg[1], selfPath)
if appDir == "" then
    print("无法定位应用目录：请先 cd 到应用根目录（含 core/ 的目录）再执行 lua main.lua")
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
local logs          = require("shared.logs")
local state         = require("shared.state")
local utils         = require("shared.utils")
local scheduler     = require("core.scheduler")
local runtime       = require("core.runtime")
local files         = require("backend.store.files")
local trace         = require("backend.store.trace")
local log_file      = require("backend.store.log_file")
local records       = require("backend.store.records")
local history       = require("backend.store.history")
local levels_config = require("backend.store.levels_config")
local jobs          = require("backend.jobs")
local handlers      = require("backend.handlers")
local api           = require("backend.api")
local power         = require("backend.domain.power")
local net           = require("backend.hardware.net")
local render        = require("frontend.render")
files.setRoot(appDir)
trace.start(appDir, bootstrap.version())
if memwatch then memwatch.traceBoot(bootFree, bootTotal) end
logs.system(bootstrap.versionLine())
logs.debug("[调试] 应用目录 " .. appDir
    .. (removed > 0 and ("（已清掉 " .. removed .. " 个旧模块缓存）") or ""))
local taskCount = jobs.register()
logs.debug(string.format("[调试] 已注册 %d 个定时任务；日志级别 = %s", taskCount, logs.getLevel()))
local _, ruleText             = levels_config.load()
local gotRecords, recordText  = records.load()
local gotHistory, historyText = history.load()
power.refresh()
logs.debug("[调试] " .. tostring(ruleText))
logs.debug("[调试] " .. tostring(recordText) .. (gotRecords and "" or "（将从建议值开始学习）"))
logs.debug("[调试] " .. tostring(historyText))
local subCount = handlers.subscribe()
logs.debug(string.format("[调试] 已订阅 %d 类事件", subCount))
runtime.discardStaleInterrupts()
runtime.bindQuitKeys()
local savedSettings = require("backend.store.settings").load()
if savedSettings and (savedSettings.priority == "high" or savedSettings.priority == "low") then
    state.system.priority = savedSettings.priority
    logs.system(string.format("运行模式：%s（来自上次保存）",
        savedSettings.priority == "high" and "高级水优先" or "低级水优先"))
else
    state.system.priority = CONFIG.SYSTEM.PRIORITY_DEFAULT or "low"
end
net.setEnabled(CONFIG.NET.ENABLED == true)
if net.register() then
    net.setSource(api.snapshot)
    logs.debug(string.format("[调试] 广播任务已注册（当前 %s）",
        state.net.enabled and "开" or "关"))
end
render.boot()
logs.system("界面已就绪（点按钮或快捷键 X/P/R/T）")
if CONFIG.SYSTEM.START_ON_BOOT then
    require("backend.app.system").start("开机自启")
end
runtime.run(render.frame)
do
    render.restoreResolution()
    bootstrap.releaseConsole()
    if state.system.running then
        require("backend.app.system").stop("程序退出")
    end
    local okHistory, historyNote = history.save()
    if not okHistory then logs.warn(tostring(historyNote)) end
    if memwatch then memwatch.watch(jobs.elapsed()) end
    log_file.flush()
    local j       = jobs.last()
    local memText = memwatch and memwatch.summary()
    trace.stop(runtime.quitReason(), string.format(
        "运行 %.0f 秒，硬件扫描 %d 次，水位 %s，总功率 %s，记录 %d 级，历史 %d 点%s",
        jobs.elapsed(), j.scanCount,
        j.fluidOk and "读取成功" or ("读取失败(" .. tostring(j.fluidErr) .. ")"),
        utils.formatNumber(j.powerBefore or 0), records.count(),
        state.chart and #state.chart.points or 0,
        memText and ("，内存 " .. memText) or ""))
end
print("已退出：" .. tostring(runtime.quitReason() or "未说明"))
print("运行痕迹：" .. tostring(trace.path()))
