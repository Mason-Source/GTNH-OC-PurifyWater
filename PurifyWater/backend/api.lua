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
-- read 返回新表：前端拿到的永远是副本，免得界面顺手改一下 state 就把后端带歪。
--------------------------------------------------------------------------------

local constants     = require("shared.constants")
local logs          = require("shared.logs")
local state         = require("shared.state")
local runtime       = require("core.runtime")
local scheduler     = require("core.scheduler")

local jobs          = require("backend.jobs")
local app           = require("backend.app.system")
local plan          = require("backend.app.plan")
local power         = require("backend.domain.power")
local rules         = require("backend.domain.rules")

local levels_config = require("backend.store.levels_config")
local history       = require("backend.store.history")
local net           = require("backend.hardware.net")

local api           = { read = {} }

--------------------------------------------------------------------------------
-- 只读
--------------------------------------------------------------------------------

--- 系统状态（界面正文只需这三个）
-- @return table
function api.read.system()
    return {
        running  = state.system.running == true,
        locked   = state.system.locked == true,
        priority = state.system.priority
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
        local snap = state.plant(level)
        local rule = state.rules[level] or { threshold = 0, enabled = false }
        -- 【逐台机器】详情页要"每台机器分别的当前并行 / 真实并行 / 成功率"：
        --   **只拷界面要的字段**（不给内部表）；confirmed 取自 tracker（这台机器确认过的值）
        local perMachine = {}
        for i, m in ipairs(snap.machines or {}) do
            local track = state.tracker[m.address]
            perMachine[i] = {
                address = m.address,
                active = m.active,
                current = m.parallel,                        -- 当前并行（本周期传感器读数）
                success = m.success,                         -- 当前成功率
                confirmed = track and track.confirmed or nil -- 真实并行（连续 N 周期确认过的）
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
            parallel = snap.parallel,
            source = snap.source,
            machines = perMachine,
            openable = snap.openable,
            forced = snap.forced,
            reason = snap.reason,
            water = state.fluids[level],
            rule = { threshold = rule.threshold or 0, enabled = rule.enabled == true },
            reserveLine = rules.reserveLine(level),
            suggest = power.suggest(level)
        }
    end
    return out
end

--- 功率（全厂可用 / 本轮已用 / 剩余 + 逐级预估）
-- @return table
function api.read.power()
    return {
        all = state.power.all or 0,
        used = (state.power.all or 0) - (state.power.budget or 0),
        budget = state.power.budget or 0
    }
end

--- 本轮方案：只给无线快照用（镜像端只显示"开 T1/T3 …还是全关"）
-- @return table
function api.read.plan()
    local opened = {}
    for level = 1, constants.LEVEL_COUNT do
        if state.lastPlan[level] == true then opened[#opened + 1] = level end
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

--- 主机（level 0）只要一个总开关 + 运行周期进度
-- 主机就是总控：它的开关代表"允不允许各级水厂跑"，值由 T3 写进内存快照，这里只转出来。
-- 周期进度：各水厂周期同步，界面上只画主机这一个（进度条 = progress / progressMax）。
-- @return table { switch = true|false|nil, progress = number|nil, progressMax = number|nil }
function api.read.host()
    local snap = state.plant(constants.HOST_LEVEL)
    return {
        switch = snap.switch,
        progress = snap.progress,
        progressMax = snap.progressMax
    }
end

--- 给无线广播用的快照（镜像端只读这份）
-- 【一份数据只组装一次】api.read.* 已经是"只读副本"，这里把它们打包
-- @return table
function api.snapshot()
    return {
        system = api.read.system(),
        hardware = api.read.hardware(),
        power = api.read.power(),
        plan = api.read.plan(),
        host = api.read.host(),
        levels = api.read.levels()
    }
end

--------------------------------------------------------------------------------
-- 命令
--------------------------------------------------------------------------------

-- 命令表：**前端能做什么，看这一张表就够了**（界面上的按钮名 -> 这里的键）
local COMMANDS = {}

COMMANDS.system_toggle = function()
    local running = app.toggle("界面")
    return true, running and "已启动系统" or "已停机"
end

COMMANDS.system_start = function()
    app.start("界面")
    return true, "已启动系统"
end

COMMANDS.system_stop = function()
    app.stop("界面")
    return true, "已停机"
end

COMMANDS.priority_toggle = function()
    -- 日志由 plan.togglePriority 写（含“是否保存成功”），这里不再返回文案避免重复
    plan.togglePriority()
    return true, ""
end

COMMANDS.schedule_now = function()
    -- 没在跑/已锁定就不去试
    if not state.isActive() then return false, "系统没在跑或已锁定，未重排" end
    -- plan.run 短路（方案没变）时不回"已重排"，免得日志里出现一句做不到的话
    if not plan.run("界面") then return false, "方案没变，未重排" end
    return true, ""
end

COMMANDS.refresh = function()
    jobs.scanHardware()
    jobs.readFluids()
    jobs.observePlants()
    scheduler.emit("schedule_now", { reason = "界面刷新" })
    return true, "已刷新"
end

--- 改阈值/勾选：写文件 -> T2 的变更检测广播 level_rules_changed（界面不直接喊调度）
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
        return false, "写阈值文件失败"
    end
    levels_config.load() -- 立刻生效（不等下一个 5 秒）
    scheduler.emit("level_rules_changed", {
        why = string.format("%s 阈值已改", constants.levelLabel(level))
    })
    return true, "已保存"
end

COMMANDS.level_enabled_toggle = function(level)
    level = tonumber(level)
    local rule = state.rules[level]
    if not rule then return false, "无该级配置" end
    return COMMANDS.level_rules_set(level, rule.threshold, not rule.enabled)
end

COMMANDS.net_toggle = function()
    return true, net.toggle()
end

--- 切日志级别（界面点日志面板标题）：user 看业务，debug 看排错细节
COMMANDS.log_level_toggle = function()
    logs.setLevel(logs.isDebug() and "user" or "debug")
    return true, "日志级别：" .. logs.getLevel()
end

COMMANDS.quit = function()
    runtime.quit("界面退出")
    return true, "正在退出"
end

--- 发一条命令（前端唯一的写入口）
-- @param command string 命令名（见上面 COMMANDS）
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
