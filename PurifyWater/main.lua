-- 主控入口：按 V1 定位器确定应用目录，再装配最小运行链。
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

local storage = require("services.storage")
storage.setRoot(appDir)

local event = require("event")
local config = require("shared.config")
local kernel = require("core.kernel")
local state = require("services.state")
local work = require("services.work")
local ui = require("frontend.app")
local config_service = require("services.config_service")
local autostart_service = require("services.autostart_service")
local net_service = require("services.net_service")
local log_flush = require("services.log_flush")
local read_model = require("services.read_model")
local hardware_service = require("services.hardware_service")
local produce_service = require("services.produce_service")
local schedule_service = require("services.schedule_service")
local produce_runtime = require("services.produce_runtime")
local history_service = require("services.history_service")
local log = require("services.log")
local clock = require("services.clock")

local function wait(delay)
    local values = { event.pull(delay) }
    if values[1] == nil then return nil end
    return values
end

local exitReason = "程序退出"

local function run()
    local quitting = false
    local uiDirty = false
    state.start(clock.uptime())
    local configOk, configErr = config_service.load()
    if not configOk then log.error("配置载入失败：" .. tostring(configErr)) end
    autostart_service.refresh()
    net_service.setSource(read_model.snapshot)
    net_service.load(clock.uptime())
    log_flush.load(clock.uptime())
    hardware_service.load()
    produce_service.load()
    schedule_service.load()
    produce_runtime.load()
    history_service.load()
    log.system("PurifyWater " .. bootstrap.version() .. " 启动")
    ui.boot({ theme = state.get().settings.theme })
    ui.setActionHandler(function(name, action)
        if name == "quit" then
            produce_service.cancelBind()
            exitReason = "用户退出"
            quitting = true
            return true
        end
        if name == "refresh" then
            hardware_service.requestRefresh()
            produce_service.requestRefresh()
            return true
        end
        local recognized, ok, err = schedule_service.handle(name, action)
        if recognized then
            if ok == false and err and err ~= "" then log.warn("操作未完成：" .. tostring(err)) end
            return ok
        end
        recognized, ok, err = produce_service.handle(name, action)
        if recognized then
            if ok == false and err and err ~= "" then log.warn("操作未完成：" .. tostring(err)) end
            return ok
        end
        recognized, ok, err = net_service.handle(name)
        if recognized then
            if ok == false and err and err ~= "" then log.warn("操作未完成：" .. tostring(err)) end
            return ok
        end
        recognized, ok, err = autostart_service.handle(name)
        if recognized then
            if ok == false and err and err ~= "" then log.warn("操作未完成：" .. tostring(err)) end
            return ok
        end
        ok, err = config_service.handle(name, action)
        if ok == false and err and err ~= "" then log.warn("操作未完成：" .. tostring(err)) end
        return ok
    end)

    local uiReadyLogged = false
    ui.setObserver(function(kind, data)
        if kind == "frame" and not uiReadyLogged and (data.draws or 0) > 0 then
            uiReadyLogged = true
            log.diag(string.format("界面就绪：绘制 %d 项，页面 %s",
                data.draws, tostring(data.page or "-")))
        end
    end)

    kernel.run({
        clock = clock.uptime,
        wait = wait,
        input = function(signal)
            if signal[1] == "interrupted" then
                produce_service.cancelBind()
                exitReason = "程序中断"
                quitting = true
            elseif signal[1] == "key_down" and signal[3] == 113 then
                produce_service.cancelBind()
                exitReason = "用户退出"
                quitting = true
            else
                if ui.handle(signal) then uiDirty = true end
            end
        end,
        quit = function() return quitting end,
        nextDue = work.nextDue,
        step = function(now)
            if uiDirty then
                uiDirty = false
                ui.frameInput()
                return
            end

            local item = work.select(now)
            if not item then return end
            state.setNow(now)

            local ok, result = pcall(item.run, now)
            local finishedAt = clock.uptime()
            state.setNow(finishedAt)
            if not ok then
                log.error("后台任务失败：" .. tostring(result))
                log.diag("任务：" .. tostring(item.name))
            end
            if ok then
                work.after(item, finishedAt, result == true)
            else
                work.fail(item, finishedAt)
            end

            ui.frameData()
        end,
    })
end

local ok, fatalError = xpcall(run, debug.traceback)
if not ok then log.error("程序异常退出：" .. tostring(fatalError)) end

local shutdownOk, shutdownErr = schedule_service.shutdownNow(exitReason)
if not shutdownOk then log.warn("退出全关失败：" .. tostring(shutdownErr)) end
local historyOk, historyErr = history_service.save()
if not historyOk then log.warn("退出时历史保存失败：" .. tostring(historyErr)) end

local runtimeData = state.get()
local runSeconds = math.max(0, (tonumber(clock.uptime()) or 0) - (tonumber(runtimeData.startedAt) or 0))
log.system(string.format("PurifyWater 已退出：%s｜运行 %.0f 秒", tostring(exitReason), runSeconds))

local logOk, logPathOrErr = log.flush()

ui.restoreResolution()
bootstrap.releaseConsole(config.UI.EXIT_LOG_ROW or 1)

print(string.format("已退出：%s｜运行 %.0f 秒", tostring(exitReason), runSeconds))
if logOk then
    print("日志：" .. tostring(logPathOrErr))
else
    print("日志写入失败：" .. tostring(logPathOrErr))
end
print("开机自启动：" .. (runtimeData.settings.autostart == true and "已开启" or "未开启"))