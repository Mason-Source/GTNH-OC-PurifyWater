--------------------------------------------------------------------------------
-- backend/app/produce_runtime.lua
--------------------------------------------------------------------------------
-- 【职责】制作 operation 调度：runAt、priority、coroutine 恢复、周期门控。
-- 【不做什么】不认识 T3/T4/T5/T7/T8 业务；每拍最多恢复一个 job。
--------------------------------------------------------------------------------

local computer = require("computer")
local logs     = require("shared.logs")
local utils    = require("shared.utils")

local runtime = {}
local jobs    = {}

local function now() return computer.uptime() end

local function fail(job, reason)
    logs.warn(string.format("制作自动化 operation 失败（%s）：%s",
        tostring(job.id), tostring(reason)))
    jobs[job.id] = nil
end

--- 本轮实际转移摘要（按首次转移顺序聚合数量）
-- @param job table
-- @return string
local function transferSummary(job)
    local trace = job.ctx and job.ctx.trace
    if not trace or #trace.order == 0 then return "无" end
    local parts = {}
    for _, entry in ipairs(trace.order) do
        local amount = utils.formatNumber(entry.amount)
        if entry.kind == "fluid" then
            parts[#parts + 1] = string.format("%s %s mB", tostring(entry.label), amount)
        else
            parts[#parts + 1] = string.format("%s×%s", tostring(entry.label), amount)
        end
    end
    return table.concat(parts, "、")
end

--- operation 正常完成：user 级提示谁完成，debug 级记录本轮转移内容。
-- @param job table
local function complete(job)
    local label = job.levelLabel or ("T" .. tostring(job.level))
    local who   = job.machineText or tostring(job.machine)
    logs.system(string.format("%s 制作自动化：本轮完成（机器 %s）", label, who))
    logs.debug(string.format("%s 制作自动化：本轮转移 %s（机器 %s）",
        label, transferSummary(job), who))
    jobs[job.id] = nil
end

function runtime.add(job)
    assert(type(job) == "table" and type(job.operation) == "function", "invalid operation")
    assert(type(job.executor) == "function", "invalid executor")
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
        if a == false then fail(job, b or "operation 失败") else complete(job) end
        return
    end
    if type(a) ~= "table" then fail(job, "operation 返回无效请求") return end
    if a.kind == "wait" then
        job.runAt = now() + math.max(0.05, tonumber(a.seconds) or 0.05)
        return
    end
    if a.kind == "action" then
        local okExec, result = pcall(job.executor, a.action, job)
        if not okExec then fail(job, result) return end
        if type(result) ~= "table" then fail(job, "executor 返回无效结果") return end
        job.pending = result
        job.runAt = now() + 0.05
        return
    end
    fail(job, "未知 operation 请求：" .. tostring(a.kind))
end

--- 执行一拍：最多恢复一个 operation。
function runtime.tick()
    local job = pickDue(now())
    if not job then return end
    if gate(job) then resume(job) end
end

return runtime
