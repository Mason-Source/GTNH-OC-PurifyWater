--------------------------------------------------------------------------------
-- backend/app/produce_runtime.lua
--------------------------------------------------------------------------------
-- 【职责】制作任务调度：runAt、priority、coroutine 恢复、周期门控。
-- 【不做什么】不认识 T3/T4/T5/T7/T8 业务；每拍最多恢复一个 job。
--------------------------------------------------------------------------------

local computer = require("computer")
local logs     = require("shared.logs")

local runtime = {}
local jobs    = {}

local function now() return computer.uptime() end

local function fail(job, reason)
    jobs[job.id] = nil
    local where = tostring(job.machineText or job.machine or job.id or "?")
    if job.levelLabel then where = tostring(job.levelLabel) .. " " .. where end
    logs.warn(string.format("制作自动化任务失败（%s）：%s", where, tostring(reason)))
end


--- 制作任务正常完成：先释放 job，再写用户级提示。
-- @param job table
local function complete(job)
    jobs[job.id] = nil
    local label = job.levelLabel or ("T" .. tostring(job.level))
    local who   = job.machineText or tostring(job.machine)
    logs.system(string.format("%s 制作自动化：本轮完成（机器 %s）", label, who))
end

function runtime.add(job)
    assert(type(job) == "table" and type(job.operation) == "function", "无效的制作任务")
    assert(type(job.executor) == "function", "无效的执行器")
    job.runAt    = tonumber(job.runAt) or now()
    job.priority = tonumber(job.priority) or 100
    job.ctx.action = function(action)
        return coroutine.yield({ kind = "action", action = action })
    end
    job.ctx.wait = function(seconds)
        seconds = tonumber(seconds)
        if not seconds or seconds < 0 then seconds = 0.05 end
        return coroutine.yield({ kind = "wait", seconds = seconds })
    end
    job.co = coroutine.create(function() return job.operation(job.ctx) end)
    jobs[job.id] = job
    return job
end

function runtime.has(id)
    return id ~= nil and jobs[id] ~= nil
end

--- 按谓词批量取消 job；周期切换和门控复检共用。
function runtime.cancelWhere(predicate)
    local n = 0
    for id, job in pairs(jobs) do
        if type(job) == "table" and predicate(job) then
            jobs[id] = false
            n = n + 1
        end
    end
    if n > 0 then
        for id, job in pairs(jobs) do
            if job == false then jobs[id] = nil end
        end
    end
    return n
end

local function pickDue(t)
    local picked
    for _, job in pairs(jobs) do
        if job.runAt <= t then
            if not picked
                or job.priority < picked.priority
                or (job.priority == picked.priority and job.runAt < picked.runAt) then
                picked = job
            end
        end
    end
    return picked
end

local function gate(job)
    if not job.gate then return true end
    local ok, allowed = pcall(job.gate)
    if not ok then
        fail(job, allowed)
        return false
    end
    if allowed then return true end
    jobs[job.id] = nil
    return false
end

local function resume(job)
    local ok, a, b
    if job.pending then
        ok, a, b = coroutine.resume(job.co, job.pending)
        job.pending = nil
    else
        ok, a, b = coroutine.resume(job.co)
    end
    if not ok then fail(job, a) return end
    if coroutine.status(job.co) == "dead" then
        if a == false then fail(job, b or "制作任务失败") else complete(job) end
        return
    end
    if type(a) ~= "table" then fail(job, "制作任务返回无效请求") return end
    if a.kind == "wait" then
        job.runAt = now() + math.max(0.05, tonumber(a.seconds) or 0.05)
        return
    end
    if a.kind == "action" then
        local okExec, result = pcall(job.executor, a.action, job)
        if not okExec then fail(job, result) return end
        if type(result) ~= "table" then fail(job, "执行器返回无效结果") return end
        job.pending = result
        job.runAt = now() + 0.05
        return
    end
    fail(job, "未知的制作任务请求：" .. tostring(a.kind))
end

--- 执行一拍：最多恢复一个制作任务。
function runtime.tick()
    local job = pickDue(now())
    if not job then return end
    if gate(job) then resume(job) end
end

return runtime
