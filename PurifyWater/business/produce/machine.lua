--------------------------------------------------------------------------------
-- PurifyWater/business/produce/machine.lua
--
-- 定位：制作状态机的通用解释器。
-- 功能：定义命令、跳转、等待、完成和失败动作，并驱动任务状态迁移。
-- 边界：不访问组件；外部命令执行器由运行时注入，保证状态机逻辑可独立测试。
--------------------------------------------------------------------------------

local machine = {}

local function validStep(value)
    return type(value) == "table"
end

--- 构造一个需要由运行时执行并回传结果的状态机命令。
function machine.command(kind, fields, nextState)
    local command = { kind = tostring(kind or "") }
    for key, value in pairs(fields or {}) do command[key] = value end
    return { command = command, nextState = nextState }
end

--- 构造无外部调用的状态跳转动作。
function machine.jump(nextState)
    return { jump = nextState }
end

--- 构造带最短等待时间的状态跳转动作。
function machine.wait(seconds, nextState)
    return { wait = math.max(0.05, tonumber(seconds) or 0.05), nextState = nextState }
end

--- 构造制作任务完成结果。
function machine.done()
    return { status = "done" }
end

--- 构造制作任务失败结果，可附带结构化故障信息。
function machine.fail(reason, failure)
    return { status = "failed", reason = tostring(reason or "制作任务失败"), failure = failure }
end

--- 根据等级实现定义创建普通数据任务实例。
function machine.create(definition, entry, now)
    local task = definition.build(entry, now) or {}
    task.entry = entry
    task.state = task.state or definition.initial
    task.event = nil
    return task
end

--- 执行一次状态机步骤并解释其返回动作。
--- 状态函数签名为 `definition.states[state](task, event, now, env)`。
---@param task table 任务实例。
---@param definition table 制作方法定义。
---@param now number 当前时间。
---@param env table 运行时环境。
---@param execute function 单次命令执行器。
---@return table response 状态机响应。
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