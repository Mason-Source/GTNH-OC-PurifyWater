--------------------------------------------------------------------------------
-- main.lua   —— 控制端入口（界面 + 调度）
--------------------------------------------------------------------------------
-- 【启动顺序（规范，加东西都按这个顺序）】
--   ① 定位应用目录并注入 require 路径（此时还不能 require 工程模块）
--   ② 清旧模块缓存 + 解析参数 + 注入数据根目录 + 写运行痕迹
--   ③ 注册定时任务（T1-T7）+ 读回记录与阈值 + 订阅事件与退出语义
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

-- ② 卫生工作
local bootstrap = require("core.bootstrap")
local removed   = bootstrap.clearModuleCache()
bootstrap.applyArgs({ ... })

-- 【内存观测：只在 --debug 下做（决策 32）】整套观测在 `backend/debug/memwatch`，日常运行连模块都不装。
--   这里只负责在**任何本工程模块之前**取一次读数：此刻只装了引导模块（`bootstrap` 已装过 `logs`），
--   这个数 ≈ **OpenOS shell 占掉的那部分**（实机 2048K 上限下是 421K，见 ARCHITECTURE 决策 31）。
local memwatch, bootFree, bootTotal = nil, nil, nil
if require("shared.logs").isDebug() then
    bootFree  = require("computer").freeMemory()
    bootTotal = require("computer").totalMemory()
    memwatch  = require("backend.debug.memwatch") -- 只有 --debug 才装这个模块
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

files.setRoot(appDir) -- 数据文件（配置里的相对名）都相对应用目录解析

trace.start(appDir, bootstrap.version())
if memwatch then memwatch.traceBoot(bootFree, bootTotal) end -- 两行内存读数只在 --debug 下写

logs.system(bootstrap.versionLine())
-- 下列都是排查信息（不是用户要看的东西）：应用目录、任务与事件条数、各数据文件的加载行数……
logs.debug("[调试] 应用目录 " .. appDir
    .. (removed > 0 and ("（已清掉 " .. removed .. " 个旧模块缓存）") or ""))

-- ③ 任务、数据、事件
local taskCount = jobs.register()
logs.debug(string.format("[调试] 已注册 %d 个定时任务；日志级别 = %s", taskCount, logs.getLevel()))

-- 注册后已各跑一次（T1 拿到功率、T2 拿到水位），此时读盘才有意义
local _, ruleText             = levels_config.load()
local gotRecords, recordText  = records.load()
local gotHistory, historyText = history.load()
power.refresh()
logs.debug("[调试] " .. tostring(ruleText))
logs.debug("[调试] " .. tostring(recordText) .. (gotRecords and "" or "（将从建议值开始学习）"))
logs.debug("[调试] " .. tostring(historyText))

-- 【事件接线本身不能删】下面这行才是"把事件表挂上"的动作；条数只是排查信息
local subCount = handlers.subscribe()
logs.debug(string.format("[调试] 已订阅 %d 类事件", subCount))

runtime.discardStaleInterrupts() -- 先丢掉上一个进程残留的 interrupted
runtime.bindQuitKeys()

-- 【开机默认值】运行模式是**永久配置**：存过就用存的，没存过才用 config 默认
-- （其余界面开关如无线广播仍只活在内存里，重启回到 config）
local savedSettings = require("backend.store.settings").load()
if savedSettings and (savedSettings.priority == "high" or savedSettings.priority == "low") then
    state.system.priority = savedSettings.priority
    logs.system(string.format("运行模式：%s（来自上次保存）",
        savedSettings.priority == "high" and "高级水优先" or "低级水优先"))
else
    state.system.priority = CONFIG.SYSTEM.PRIORITY_DEFAULT or "low"
end
net.setEnabled(CONFIG.NET.ENABLED == true)

-- ④ 广播（T7）：快照来源由这里注入，避免 net 反过来 require api 造成环依赖
if net.register() then
    net.setSource(api.snapshot)
    logs.debug(string.format("[调试] 广播任务已注册（当前 %s）",
        state.net.enabled and "开" or "关"))
end

render.boot()
logs.system("界面已就绪（点按钮或快捷键 X/P/R/T）")

-- 无人值守机房：想让程序一启动就自动开调度，把 CONFIG.SYSTEM.START_ON_BOOT 改成 true
if CONFIG.SYSTEM.START_ON_BOOT then
    require("backend.app.system").start("开机自启")
end

runtime.run(render.frame)

-- ⑤ 收尾：停机 + 存盘 + 痕迹
-- 【先还原屏幕】render.boot 可能按配置改过分辨率（放大字体），退出前原样还回去
-- 【再刷干净】退出信息不能压在界面残影上（见 bootstrap.releaseConsole）；
--   放在这里而不是 `print` 前：收尾里任何一步出错，报错也落在干净屏上。
do
    render.restoreResolution()
    bootstrap.releaseConsole()
    if state.system.running then
        require("backend.app.system").stop("程序退出")
    end
    local okHistory, historyNote = history.save()
    if not okHistory then logs.warn(tostring(historyNote)) end

    if memwatch then memwatch.watch(jobs.elapsed()) end -- 退出前再看一眼：痕迹里那两个数才是最终值
    log_file.flush()                                    -- 内存里还没落盘的日志补上（正常退出不会丢；崩溃最多丢半分钟）
    local j       = jobs.last()
    local memText = memwatch and memwatch.summary()     -- 没带 --debug 时为 nil，摘要里就没有内存那段
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
