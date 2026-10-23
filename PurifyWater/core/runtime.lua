--------------------------------------------------------------------------------
-- core/runtime.lua
--------------------------------------------------------------------------------
-- 【职责】主循环：拉事件 -> 派发 -> 跑到期任务 -> 帧钩子；以及退出语义
-- 【不做什么】不注册任务、不订阅业务事件（backend/jobs、backend/handlers）
-- 【依赖】event / computer、core/scheduler、shared/{config,logs}
-- 【被谁用】main.lua、monitor.lua
--
-- 一帧：event.pull(clamp(最近到期, MIN, MAX)) -> emit -> tick -> drain -> frame。
--
-- event.pull 返回多个值：必须包成表，否则只拿到事件名，订阅会静默失效。
--
-- timeout 必须夹紧：不夹会忙等或界面不刷新。
--------------------------------------------------------------------------------

local event      = require("event")
local computer   = require("computer")
local CONFIG     = require("shared.config")
local logs       = require("shared.logs")
local utils      = require("shared.utils")
local scheduler  = require("core.scheduler")

local runtime    = {}

local quitting   = false
local quitReason = nil

--------------------------------------------------------------------------------
-- 退出
--------------------------------------------------------------------------------

--- 请求退出主循环（任何地方都能调；主循环会在本帧结束后返回）
-- @param reason string|nil 退出原因（写日志用）
function runtime.quit(reason)
    if quitting then return false end
    quitting   = true
    quitReason = reason or "程序退出"
    return true
end

--- 本次退出的原因
-- @return string|nil
function runtime.quitReason() return quitReason end

--------------------------------------------------------------------------------
-- 主循环
--------------------------------------------------------------------------------

--- 丢掉上个进程残留的 interrupted（否则刚启动即退出）；其它事件照常入队。
-- @return number 丢掉的条数
function runtime.discardStaleInterrupts()
    local dropped = 0
    for _ = 1, 20 do
        local ev = { event.pull(0) }
        if ev[1] == nil then break end
        if ev[1] == "interrupted" then
            dropped = dropped + 1
        else
            scheduler.emit(ev[1], ev)
        end
    end
    return dropped
end

--- 夹紧等待时长
-- @param wait number
-- @return number
local function clampWait(wait)
    local min = CONFIG.LOOP_MIN_IDLE or 0.05
    local max = CONFIG.LOOP_MAX_IDLE or 1.0
    if type(wait) ~= "number" or wait ~= wait then return max end
    if wait < min then return min end
    if wait > max then return max end
    return wait
end

--- 跑一帧
-- @param onFrame function|nil 帧钩子（在到期任务与事件派发之后调）
-- @return boolean 是否已请求退出
function runtime.frame(onFrame)
    local now  = computer.uptime()
    local wait = clampWait(scheduler.secondsUntilDue(now))

    -- ① 等事件（超时也回来）
    -- event.pull 返回多值，必须包成表（见文件头）
    local ev   = { event.pull(wait) }
    if ev[1] ~= nil then
        scheduler.emit(ev[1], ev)
    end
    if quitting then return true end

    -- ② 跑到期任务、派发事件、刷一帧
    scheduler.tick(computer.uptime())
    scheduler.drain()
    if onFrame then onFrame() end

    return quitting
end

--- 主循环（直到有谁调用 runtime.quit）
-- @param onFrame function|nil 帧钩子（每帧调一次：绘界面 + 处理输入）
function runtime.run(onFrame)
    while not quitting do
        runtime.frame(onFrame)
    end
    logs.system("主循环结束：" .. tostring(quitReason or "未说明原因"))
end

--------------------------------------------------------------------------------
-- 常用订阅：退出相关（各入口调用一次即可）
--------------------------------------------------------------------------------

--- 订阅退出事件：Ctrl+C 与 Q。
-- char 是 ASCII 码数字，部分布局为 0；用 utils.isKey 双判据。
function runtime.bindQuitKeys()
    scheduler.on("interrupted", function()
        runtime.quit("Ctrl+C")
    end)
    scheduler.on("key_down", function(ev)
        local char, code = ev[3], ev[4]
        if utils.isKey(char, code, "q") then runtime.quit("按键 Q") end
    end)
end

return runtime
