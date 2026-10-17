--------------------------------------------------------------------------------
-- backend/api.lua
--------------------------------------------------------------------------------
-- 【职责】**唯一对外面**：前端只从这里拿数据（`api.read.*`）和发命令（`api.exec`）
-- 【不做什么】不判断、不算、不写盘、不碰组件 —— 只做"转发 + 组装只读副本"
-- 【依赖】shared/*、backend/{jobs,app/*,domain/*,store/*,hardware/net}、core/*
-- 【被谁用】frontend/viewmodel（读）、frontend/input（写）、main.lua / monitor.lua
--
-- 【命名说明】设计文档里叫 `api.do(...)`，但 **`do` 是 Lua 关键字**（`api.do` 不是合法字段访问），
--   所以落地名就叫 `api.exec(command, ...)`：只差一个名字，语义不变。
--
-- 【铁律】前端只 require `backend.api`，不直接 require backend 里别的模块。
--   这样"前端改不了机器、后端也不必知道界面长什么样"是**结构性**保证，不靠自觉。
-- read 返回新表：前端只拿副本，改 state 不影响后端。
--------------------------------------------------------------------------------

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
local produceApp   = require("backend.app.produce")
local power         = require("backend.domain.power")
local rules         = require("backend.domain.rules")

local levels_config = require("backend.store.levels_config")
local history       = require("backend.store.history")
local net           = require("backend.hardware.net")

local api           = { read = {} }

--------------------------------------------------------------------------------
-- 只读
--------------------------------------------------------------------------------

--- 系统状态（界面正文只需前三个；后三个给配置页「运行设置」）
-- @return table
function api.read.system()
    return {
        running  = state.read.running() == true,
        awaiting = state.read.awaiting() == true,
        priority = state.read.priority(),
        -- 调度模式：阈值 / 速率；速率模式的子参数与 T7 增产倍率（配置页读它们）
        mode             = state.read.mode(),
        enforceThreshold = state.read.enforceThreshold() == true,
        t7Boost          = state.read.t7Boost(),
        energyFactor     = state.read.energyFactor(), -- 能源仓利用因子（%）：可用 = 最大 × 因子
        -- 配置表格各列算不算数（勾选/阈值/权重/增产）：判定只有一处（app/system.effectiveConfig），
        --   界面照着灰显与写日志（不生效的照样能改，只是"已保存待用"）
        effectiveConfig  = app.effectiveConfig(),
        -- 开机自启：真源 = $HOME/.shrc 里那段标记块（见 backend/store/autostart）
        autostart      = state.read.autostart() == true,
        autostartStale = state.read.autostartStale() == true,
        autostartPath  = state.read.autostartPath()
    }
end

--- 硬件采集摘要
-- @return table
function api.read.hardware()
    local last = jobs.last()
    local s    = last.summary or { host = 0, unitTotal = 0, energy = false }
    return {
        host = s.host,
        units = s.unitTotal,
        energy = s.energy and 1 or 0, -- 单仓：1 = 已绑定（广播协议要数字）
        me = last.meOk == true,
        missing = last.missing or {}
    }
end

--- 各级净水状态（界面主数据：一行一级）
-- @return table 数组，下标 = 等级
function api.read.levels()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        local snap = state.read.plant(level)
        local rule = state.read.rules()[level] or { threshold = 0, enabled = false }
        local line = rules.lines(level)
        -- 【逐台机器】详情页要"每台机器分别的当前并行 / 学习并行 / 成功率"：
        --   **只拷界面要的字段**（不给内部表）；confirmed 取自 tracker（这台机器确认过的值）
        local perMachine = {}
        for i, m in ipairs(snap.machines or {}) do
            local track = state.read.tracker()[m.address]
            perMachine[i] = {
                address = m.address,
                active = m.active,
                current = m.parallel,                        -- 当前并行（本周期传感器读数）
                success = m.success,                         -- 当前成功率
                confirmed = track and track.confirmed or nil -- 学习并行（连续 N 周期确认过的）
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

--- 制作自动化（配置表那一列的只读来源；不进无线快照）
-- @return table { levels = { [n] = { enabled, state, reason, subs, ready } } }
function api.read.produce()
    return produceApp.read()
end

--- 功率（全厂可用 / 本轮已用）
-- @return table
function api.read.power()
    return {
        all = state.read.powerAll(),
        used = state.read.powerAll() - state.read.budget()
    }
end

--- 本轮方案：只给无线快照用（镜像端只显示"开 T1/T3 …还是全关"）
-- @return table
function api.read.plan()
    local opened = {}
    for level = 1, constants.LEVEL_COUNT do
        if state.read.lastPlan()[level] == true then opened[#opened + 1] = level end
    end
    return { opened = opened }
end

--- 曲线 + 聚合（界面图表用）
-- @param window number|nil 只要最近这么多秒的点（os.time 单位；nil = 全部）
-- @return table
function api.read.history(window)
    return history.view(window)
end

--- 日志（最近 n 行，新的在后）
-- @param n number|nil 默认 12
-- @return table
function api.read.logs(n)
    local all = logs.list()
    n = n or 12
    local out = {}
    for i = math.max(1, #all - n + 1), #all do out[#out + 1] = tostring(all[i]) end
    return out
end

--- 无线广播状态
-- @return table
function api.read.net()
    return net.status()
end

--- 主机（level 0）：总开关 + 周期进度
-- 开关代表是否允许水厂跑；进度各水厂同步，只画主机。
-- @return table { switch = true|false|nil, progress = number|nil, progressMax = number|nil }
function api.read.host()
    local snap = state.read.plant(constants.HOST_LEVEL)
    return {
        switch = snap.switch,
        progress = snap.progress,
        progressMax = snap.progressMax
    }
end

--- 无线广播快照（镜像端只读）
-- @param opts table|nil { chart = boolean } 是否带上曲线（发送端降频调用）
-- @return table
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

--------------------------------------------------------------------------------
-- 命令
--------------------------------------------------------------------------------

-- 命令表：前端能做什么看这张表
local COMMANDS = {}

COMMANDS.system_toggle = function()
    local running = app.toggle("界面")
    return true, running and "已启动系统" or "已停机"
end

COMMANDS.priority_toggle = function()
    -- 日志与重排由 app 层写
    app.onPriorityToggle()
    return true, ""
end

COMMANDS.autostart_toggle = function()
    -- 日志由 app/autostart 写
    autostart.toggle()
    return true, ""
end

COMMANDS.mode_toggle = function()
    -- 日志由 app/rates 写
    ratesApp.toggleMode()
    return true, ""
end

COMMANDS.threshold_enforce_toggle = function()
    -- 日志由 app/rates 写
    ratesApp.toggleEnforceThreshold()
    return true, ""
end

--- 改单级权重（0..MAX 整数）
COMMANDS.weight_set = function(level, weight)
    local ok, text = ratesApp.setWeight(level, weight)
    if not ok then return false, text end
    return true, ""
end

--- 设定 T7 增产倍率
-- @param value number|string 只能是 constants.T7_BOOST_OPTIONS 里的档位
COMMANDS.t7_boost_set = function(value)
    local ok, text = ratesApp.setT7Boost(value)
    if not ok then return false, text end
    return true, ""
end

--- 设能源仓利用因子（1-100 整数，%）
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

--- 改阈值/勾选：改内存 + 写文件，立刻广播变更
-- @param level number
-- @param threshold number|nil 不改传 nil
-- @param enabled boolean|nil 不改传 nil
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
    levels_config.load() -- 立刻生效（不等下一个 5 秒）
    scheduler.emit("level_rules_changed", {
        why = string.format("%s 阈值已改", constants.levelLabel(level))
    })
    return true, "已保存"
end

--- 设定单级勾选
-- @param level number
-- @param enabled boolean
COMMANDS.level_enabled_set = function(level, enabled)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then
        return false, "等级无效"
    end
    if type(enabled) ~= "boolean" then return false, "勾选值无效" end
    return COMMANDS.level_rules_set(level, nil, enabled)
end

--- 切制作自动化开关（该级；开启前后端会跑静态检查）
-- @param level number
-- @param enabled boolean
COMMANDS.level_produce_set = function(level, enabled)
    local ok, text = produceApp.setEnabled(level, enabled)
    if not ok then return false, text end
    return true, ""
end

--- 开始绑定：选中的机器 + "随后出现的新转运器" 绑定（绑定中再放转运器）
-- @param level number
-- @param machine string 机器组件地址
COMMANDS.produce_bind_begin = function(level, machine)
    local ok, text = produceApp.beginBind(level, machine)
    if not ok then return false, text end
    return true, ""
end

--- 取消"绑定中"
COMMANDS.produce_bind_cancel = function()
    local ok, text = produceApp.cancelBind()
    if not ok then return false, text end
    return true, ""
end

--- 解绑某台机器（删绑定表里那一行）
-- @param machine string 机器组件地址
COMMANDS.produce_unbind = function(machine)
    local ok, text = produceApp.unbind(machine)
    if not ok then return false, text end
    return true, ""
end

--- 切广播开关：内存 + settings.txt（重启保持）
COMMANDS.net_toggle = function()
    return true, netApp.toggle()
end

--- 设无线范围（方块，0 以上整数）：由网卡夹取后落盘（有线卡 = 0）
COMMANDS.net_strength_set = function(value)
    local ok, text = netApp.setStrength(value)
    if not ok then return false, text end
    return true, ""
end

--- 切日志级别（点面板标题）
COMMANDS.log_level_toggle = function()
    logs.setLevel(logs.isDebug() and "user" or "debug")
    return true, "日志级别：" .. logs.getLevel()
end

COMMANDS.quit = function()
    runtime.quit("界面退出")
    return true, "正在退出"
end

--- 发命令（前端唯一写入口）
-- @param command string 命令名（见 COMMANDS）
-- @param ... any 参数
-- @return boolean ok
-- @return string 说明（界面可显示一行提示）
function api.exec(command, ...)
    local fn = COMMANDS[tostring(command or "")]
    if not fn then return false, "未知命令：" .. tostring(command) end
    local result, text = fn(...)
    return result ~= false, tostring(text or "")
end

return api
