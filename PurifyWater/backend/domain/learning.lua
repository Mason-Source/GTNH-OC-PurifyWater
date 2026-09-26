--------------------------------------------------------------------------------
-- backend/domain/learning.lua
--------------------------------------------------------------------------------
-- 【职责】保存**本次运行会话**确认过的单台并行
-- 【不做什么】不读写文件、不做调度、不判断开关
-- 【生命周期】每次启动、停机、暂停或锁定后清空；再次启动从建议值重新学习
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
    local snap    = state.plant(level)
    snap.parallel = parallel
    snap.success  = success or snap.success
    snap.source   = "measured"
    return true
end

--- 清空某一级或全部等级的本轮学习值
-- @param level number|nil 不传 = 全部
function learning.forget(level)
    local function clear(lv)
        local snap = state.plant(lv)
        snap.parallel, snap.source = nil, nil
    end

    if level then
        clear(level)
    else
        for lv = 1, constants.LEVEL_COUNT do clear(lv) end
    end
end

--- 清空全部本轮学习值
function learning.forgetAll()
    learning.forget(nil)
end

--- 当前内存里已学习到并行的等级数
-- @return number
function learning.count()
    local n = 0
    for lv = 1, constants.LEVEL_COUNT do
        local snap = state.plant(lv)
        if type(snap.parallel) == "number" and snap.parallel > 0
            and snap.source == "measured" then
            n = n + 1
        end
    end
    return n
end

return learning
