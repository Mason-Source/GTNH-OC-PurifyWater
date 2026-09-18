local computer  = require("computer")
local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local scheduler = {}
local tasks     = {}
local byName    = {}
local listeners = {}
local queue     = {}
local MAX_DRAIN = 200
function scheduler.every(name, interval, fn, opts)
    if byName[name] then return false end
    local task = {
        name     = name,
        interval = interval,
        fn       = fn,
        enabled  = not (opts and opts.enabled == false),
        lastRun  = computer.uptime()
    }
    tasks[#tasks + 1] = task
    byName[name] = task
    return true
end
function scheduler.setEnabled(name, on)
    local task = byName[name]
    if not task then return false end
    task.enabled = (on == true)
    return true
end
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
function scheduler.on(event, fn)
    if type(fn) ~= "function" then return end
    local list = listeners[event]
    if not list then
        list = {}
        listeners[event] = list
    end
    list[#list + 1] = fn
end
function scheduler.emit(event, payload)
    queue[#queue + 1] = { name = event, payload = payload }
end
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
