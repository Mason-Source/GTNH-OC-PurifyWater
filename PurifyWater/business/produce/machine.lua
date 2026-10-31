-- 制作状态机解释器：状态定义静态预构造，任务实例只保存普通数据。
-- 本模块不调用组件；执行器由调用方注入，保证每步最多一次外部调用。
local machine = {}

local function validStep(value)
    return type(value) == "table"
end

function machine.command(kind, fields, nextState)
    local command = { kind = tostring(kind or "") }
    for key, value in pairs(fields or {}) do command[key] = value end
    return { command = command, nextState = nextState }
end

function machine.jump(nextState)
    return { jump = nextState }
end

function machine.wait(seconds, nextState)
    return { wait = math.max(0.05, tonumber(seconds) or 0.05), nextState = nextState }
end

function machine.done()
    return { status = "done" }
end

function machine.fail(reason, failure)
    return { status = "failed", reason = tostring(reason or "制作任务失败"), failure = failure }
end

function machine.create(definition, entry, now)
    local task = definition.build(entry, now) or {}
    task.entry = entry
    task.state = task.state or definition.initial
    task.event = nil
    return task
end

-- definition.states[state](task, event, now, env)
-- 返回 machine.command/jump/wait/done/fail 之一。
function machine.step(task, definition, now, env, execute)
    if not validStep(task) then return machine.fail("制作任务结构无效") end
    local state = definition.states and definition.states[task.state]
    if type(state) ~= "function" then
        return machine.fail("未知制作状态：" .. tostring(task.state))
    end

    local event = task.event
    task.event = nil
    local action = state(task, event, now, env or {})
    if not validStep(action) then return machine.fail("制作状态返回无效结果") end

    if action.status == "done" or action.status == "failed" then
        return action
    end
    if action.command then
        if type(execute) ~= "function" then return machine.fail("制作命令执行器缺失") end
        local result = execute(action.command)
        task.state = action.nextState or task.state
        task.event = validStep(result) and result or { ok = false, err = "命令结果无效" }
        return { status = "continue" }
    end
    if action.jump then
        task.state = action.jump
        return { status = "continue" }
    end
    if action.wait then
        task.state = action.nextState or task.state
        return { status = "wait", seconds = action.wait }
    end
    return machine.fail("制作状态缺少下一步")
end

return machine