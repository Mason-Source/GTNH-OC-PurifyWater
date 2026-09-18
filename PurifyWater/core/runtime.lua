--------------------------------------------------------------------------------
-- core/runtime.lua
--------------------------------------------------------------------------------
-- 【职责】主循环：拉事件 -> 派发 -> 跑到期任务 -> 帧钩子；以及退出语义
-- 【不做什么】不注册任务、不订阅业务事件（那是 backend/jobs 与 backend/handlers）
-- 【依赖】event / computer、core/scheduler、shared/{config,logs}
-- 【被谁用】main.lua、monitor.lua
--
-- 【一帧是什么】循环的一次迭代：
--     timeout = clamp(最近到期任务, LOOP_MIN_IDLE, LOOP_MAX_IDLE)
--     ev      = { event.pull(timeout) }   -- **必须包成表**，见下方警告
--     scheduler.emit(ev[1], ev)           -- 事件入队（ev 是完整事件数组）
--     scheduler.tick(now)                 -- 到期任务（每个最多一次）
--     scheduler.drain()                   -- 派发事件（含任务里刚 emit 的）
--     frame(帧钩子)                      -- 绘制与输入（只在脏时真画）
--
-- 【必须包成表】`event.pull` 返回**多个值**（事件名, 地址, char, code, 玩家名）；
--   `local ev = event.pull(...)` 只拿到事件名字符串 -> `ev[1]` 是 nil -> 事件以 nil 为名发出
--   -> 订阅全部静默失效（现象：按键与 Ctrl+C 无反应而帧计数照涨）。必须 `{ event.pull(...) }`。
--
-- 【timeout 必须夹紧】不夹会忙等（到期时间已过）或界面不刷新（没有任务时永远睡）。
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

--- 丢掉"上一个进程残留的 interrupted"
-- 上一个进程残留的 interrupted 会被新进程第一帧消费，表现为"刚启动就自动退出"。
-- 只丢 interrupted，其它事件照常入队派发。
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
    if dropped > 0 then
        logs.debug(string.format("[调试] 忽略启动瞬间的 %d 个 interrupted（上一个进程的残留）", dropped))
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

    -- ① 等事件（超时也回来，不阻塞：这是"异步"的全部含义）
    -- 【必须包成表】event.pull 返回多个值，直接接第一个只会得到事件名（详见文件头）
    local ev   = { event.pull(wait) }
    if ev[1] ~= nil then
        scheduler.emit(ev[1], ev)
    end
    if quitting then return true end

    -- ② 跑到期任务 + 派发事件，最后刷新一帧界面
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

--- 订阅"退出"类事件：Ctrl+C(interrupted) 与 键盘 Q
-- 退出语义属主循环，不放业务层。
-- 【按键判据】`key_down` 的载荷排布是 (事件名, 键盘地址, char, code, 玩家名)；
--   char 是**数字 ASCII 码**（不是字符），某些布局下可能是 0，所以认 `utils.isKey`
--   （字符或扫描码两种判据），不要自己写 tostring(char) 比较。
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
