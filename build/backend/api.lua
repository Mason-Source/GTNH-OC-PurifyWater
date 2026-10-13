local CONFIG        = require("shared.config")
local constants     = require("shared.constants")
local logs          = require("shared.logs")
local state         = require("shared.state")
local runtime       = require("core.runtime")
local scheduler     = require("core.scheduler")
local jobs          = require("backend.jobs")
local app           = require("backend.app.system")
local autostart     = require("backend.app.autostart")
local ratesApp      = require("backend.app.rates")
local energyApp    = require("backend.app.energy")
local netApp       = require("backend.app.net")
local power         = require("backend.domain.power")
local rules         = require("backend.domain.rules")
local levels_config = require("backend.store.levels_config")
local history       = require("backend.store.history")
local net           = require("backend.hardware.net")
local api           = { read = {} }
function api.read.system()
    return {
        running  = state.read.running() == true,
        awaiting = state.read.awaiting() == true,
        priority = state.read.priority(),
        mode             = state.read.mode(),
        enforceThreshold = state.read.enforceThreshold() == true,
        t7Boost          = state.read.t7Boost(),
        energyFactor     = state.read.energyFactor(),
        effectiveConfig  = app.effectiveConfig(),
        autostart      = state.read.autostart() == true,
        autostartStale = state.read.autostartStale() == true,
        autostartPath  = state.read.autostartPath()
    }
end
function api.read.hardware()
    local last = jobs.last()
    local s    = last.summary or { host = 0, unitTotal = 0, energy = false }
    return {
        host = s.host,
        units = s.unitTotal,
        energy = s.energy and 1 or 0,
        me = last.meOk == true,
        missing = last.missing or {}
    }
end
function api.read.levels()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        local snap = state.read.plant(level)
        local rule = state.read.rules()[level] or { threshold = 0, enabled = false }
        local line = rules.lines(level)
        local perMachine = {}
        for i, m in ipairs(snap.machines or {}) do
            local track = state.read.tracker()[m.address]
            perMachine[i] = {
                address = m.address,
                active = m.active,
                current = m.parallel,
                success = m.success,
                confirmed = track and track.confirmed or nil
            }
        end
        out[level] = {
            level = level,
            label = constants.levelLabel(level),
            deployed = snap.deployed or 0,
            switch = snap.switch,
            active = snap.active,
            sample = snap.sample,
            success = snap.success,
            parallel = (state.read.learn(level) or {}).parallel,
            machines = perMachine,
            water = state.read.fluids()[level],
            rule = {
                threshold           = rule.threshold or 0,
                enabled             = rule.enabled == true,
                userThreshold       = line.user,
                effectiveThreshold  = line.actual,
                thresholdOverridden = line.overridden
            },
            suggest         = power.suggest(level),
            weight          = state.read.weights()[level] or 0
        }
    end
    return out
end
function api.read.power()
    return {
        all = state.read.powerAll(),
        used = state.read.powerAll() - state.read.budget()
    }
end
function api.read.plan()
    local opened = {}
    for level = 1, constants.LEVEL_COUNT do
        if state.read.lastPlan()[level] == true then opened[#opened + 1] = level end
    end
    return { opened = opened }
end
function api.read.history(window)
    return history.view(window)
end
function api.read.logs(n)
    local all = logs.list()
    n = n or 12
    local out = {}
    for i = math.max(1, #all - n + 1), #all do out[#out + 1] = tostring(all[i]) end
    return out
end
function api.read.net()
    return net.status()
end
function api.read.host()
    local snap = state.read.plant(constants.HOST_LEVEL)
    return {
        switch = snap.switch,
        progress = snap.progress,
        progressMax = snap.progressMax
    }
end
function api.snapshot(opts)
    local payload = {
        system   = api.read.system(),
        hardware = api.read.hardware(),
        power    = api.read.power(),
        plan     = api.read.plan(),
        host     = api.read.host(),
        levels   = api.read.levels(),
        logs     = api.read.logs(CONFIG.LOG.MAX_LINES),
        net      = api.read.net()
    }
    if opts and opts.chart then
        payload.history = api.read.history((CONFIG.CHART.ALL_WINDOW_DAYS or 1)
            * (CONFIG.CHART.SECONDS_PER_GAME_DAY or 86400))
    end
    return payload
end
local COMMANDS = {}
COMMANDS.system_toggle = function()
    local running = app.toggle("界面")
    return true, running and "已启动系统" or "已停机"
end
COMMANDS.priority_toggle = function()
    app.onPriorityToggle()
    return true, ""
end
COMMANDS.autostart_toggle = function()
    autostart.toggle()
    return true, ""
end
COMMANDS.mode_toggle = function()
    ratesApp.toggleMode()
    return true, ""
end
COMMANDS.threshold_enforce_toggle = function()
    ratesApp.toggleEnforceThreshold()
    return true, ""
end
COMMANDS.weight_set = function(level, weight)
    local ok, text = ratesApp.setWeight(level, weight)
    if not ok then return false, text end
    return true, ""
end
COMMANDS.t7_boost_set = function(value)
    local ok, text = ratesApp.setT7Boost(value)
    if not ok then return false, text end
    return true, ""
end
COMMANDS.energy_factor_set = function(value)
    local ok, text = energyApp.setFactor(value)
    if not ok then return false, text end
    return true, ""
end
COMMANDS.refresh = function()
    jobs.scanHardware()
    jobs.readFluids()
    jobs.observePlants()
    scheduler.emit("schedule_now", { reason = "界面刷新" })
    return true, "已刷新"
end
COMMANDS.level_rules_set = function(level, threshold, enabled)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then
        return false, "等级无效"
    end
    threshold = tonumber(threshold)
    if threshold and threshold < 0 then return false, "阈值不能为负" end
    if not levels_config.set(level, threshold, enabled) then
        return false, "写配置失败（settings.txt）"
    end
    levels_config.load()
    scheduler.emit("level_rules_changed", {
        why = string.format("%s 阈值已改", constants.levelLabel(level))
    })
    return true, "已保存"
end
COMMANDS.level_enabled_set = function(level, enabled)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then
        return false, "等级无效"
    end
    if type(enabled) ~= "boolean" then return false, "勾选值无效" end
    return COMMANDS.level_rules_set(level, nil, enabled)
end
COMMANDS.net_toggle = function()
    return true, netApp.toggle()
end
COMMANDS.net_strength_set = function(value)
    local ok, text = netApp.setStrength(value)
    if not ok then return false, text end
    return true, ""
end
COMMANDS.log_level_toggle = function()
    logs.setLevel(logs.isDebug() and "user" or "debug")
    return true, "日志级别：" .. logs.getLevel()
end
COMMANDS.quit = function()
    runtime.quit("界面退出")
    return true, "正在退出"
end
function api.exec(command, ...)
    local fn = COMMANDS[tostring(command or "")]
    if not fn then return false, "未知命令：" .. tostring(command) end
    local result, text = fn(...)
    return result ~= false, tostring(text or "")
end
return api
