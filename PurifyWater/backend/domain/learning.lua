--------------------------------------------------------------------------------
-- backend/domain/learning.lua
--------------------------------------------------------------------------------
-- 【职责】保存本次会话确认过的单台并行
-- 【不做什么】不读写文件、不调度、不判开关
-- 启动/停机/等待后清空；再次启动从建议值重学
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")

local learning  = {}

--- 记下一个等级本次运行确认过的并行
-- @param level number
-- @param parallel number
-- @param success number|nil
-- @return boolean
function learning.remember(level, parallel, success)
    if type(parallel) ~= "number" or parallel <= 0 then return false end
    state.write.learnSet(level, parallel, "measured", success)
    return true
end

--- 清空单级或全部学习值
-- @param level number|nil 不传 = 全部
function learning.forget(level)
    local function clear(lv)
        state.write.learnClear(lv)
    end

    if level then
        clear(level)
    else
        for lv = 1, constants.LEVEL_COUNT do clear(lv) end
    end
end

--- 清空全部学习值
function learning.forgetAll()
    learning.forget(nil)
end

--- 当前内存里已学习到并行的等级数
-- @return number
function learning.count()
    local n = 0
    for lv = 1, constants.LEVEL_COUNT do
        local learn = state.read.learn(lv)
        if learn and type(learn.parallel) == "number" and learn.parallel > 0
            and learn.source == "measured" then
            n = n + 1
        end
    end
    return n
end

return learning
