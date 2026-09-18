--------------------------------------------------------------------------------
-- core/scheduler.lua
--------------------------------------------------------------------------------
-- 【职责】只管"什么时候跑"：
--         * 定时任务：注册（名字 + 周期 + 任务体）、启停、到期计算、执行
--         * 事件总线：订阅（on）、发布（emit）、派发（drain）
-- 【不做什么】不认识任何业务语义（它不知道"扫描硬件"是什么）
-- 【依赖】computer（计时）、shared/{config,logs}
-- 【被谁用】core/runtime（驱动）、backend/jobs（注册任务）、backend/handlers（订阅事件）
--
-- 【三条语义】
--   ① disabled 期间不推进 lastRun -> 重新启用后下一帧立刻补跑一次
--   ② emit 是入队、drain 才派发 -> 处理器里再 emit 不会递归爆栈
--   ③ 到期时间不在这里夹紧，夹紧是主循环（runtime）的事
--------------------------------------------------------------------------------

local computer  = require("computer")
local CONFIG    = require("shared.config")
local logs      = require("shared.logs")

local scheduler = {}

local tasks     = {}  -- 数组，保持注册顺序（同帧的执行顺序 = 注册顺序）
local byName    = {}
local listeners = {}  -- event -> { fn, ... }
local queue     = {}  -- 待派发的事件 { {name=, payload=}, ... }

local MAX_DRAIN = 200 -- 单次 drain 最多派发多少条（防处理器互相 emit 成死循环）

--------------------------------------------------------------------------------
-- 定时任务
--------------------------------------------------------------------------------

--- 注册一个周期任务
-- @param name string 唯一名字（重复注册返回 false）
-- @param interval number 周期秒数
-- @param fn function(now) 任务体（**必须是一小步**，不许 sleep/长跑）
-- @param opts table|nil { enabled = boolean }（默认 enabled；enabled=false 时不推进计时）
-- @return boolean
function scheduler.every(name, interval, fn, opts)
    if byName[name] then return false end
    local task = {
        name     = name,
        interval = interval,
        fn       = fn,
        enabled  = not (opts and opts.enabled == false),
        lastRun  = computer.uptime() -- 注册当刻开始计时：注册后不会立刻执行
    }
    tasks[#tasks + 1] = task
    byName[name] = task
    return true
end

--- 启用/停用任务（停用期间不推进计时 -> 重新启用立刻补跑一次）
-- @param name string
-- @param on boolean
-- @return boolean 是否存在该任务
function scheduler.setEnabled(name, on)
    local task = byName[name]
    if not task then return false end
    task.enabled = (on == true)
    return true
end

--- 距下一次到期还有多少秒（**未夹紧**；只有启用的任务参与计算）
-- 停用任务不参与计算，否则到期时间永远在过去，主循环会忙等
-- @param now number|nil
-- @return number
function scheduler.secondsUntilDue(now)
    now = now or computer.uptime()
    local nextWait = nil
    for _, task in ipairs(tasks) do
        if task.enabled then
            local wait = task.lastRun + task.interval - now
            if wait < 0 then wait = 0 end
            if nextWait == nil or wait < nextWait then nextWait = wait end
        end
    end
    if nextWait == nil then return CONFIG.LOOP_MAX_IDLE or 1.0 end
    return nextWait
end

--- 执行所有到期任务（每个最多一次）
-- @param now number|nil
-- @return number 实际执行的任务数
function scheduler.tick(now)
    now = now or computer.uptime()
    local executed = 0
    for _, task in ipairs(tasks) do
        if task.enabled then
            local interval = task.interval
            if now - task.lastRun >= interval then
                task.lastRun = now
                task.fn(now)
                executed = executed + 1
            end
        end
    end
    return executed
end

--------------------------------------------------------------------------------
-- 事件总线
--------------------------------------------------------------------------------

--- 订阅事件
-- @param event string 事件名
-- @param fn function(payload) 处理器（**只做一小步**）
function scheduler.on(event, fn)
    if type(fn) ~= "function" then return end
    local list = listeners[event]
    if not list then
        list = {}
        listeners[event] = list
    end
    list[#list + 1] = fn
end

--- 发布事件（**入队**，真正的派发在 drain）
-- @param event string
-- @param payload any
function scheduler.emit(event, payload)
    queue[#queue + 1] = { name = event, payload = payload }
end

--- 派发队列里的事件
-- @return number 派发条数
function scheduler.drain()
    local n = 0
    while #queue > 0 do
        if n >= MAX_DRAIN then
            logs.warn("事件队列单帧超过 " .. MAX_DRAIN .. " 条（可能有处理器互相触发），已截断")
            queue = {}
            break
        end
        local item = table.remove(queue, 1)
        n = n + 1
        for _, fn in ipairs(listeners[item.name] or {}) do
            fn(item.payload)
        end
    end
    return n
end

return scheduler
