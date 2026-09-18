--------------------------------------------------------------------------------
-- backend/hardware/net.lua
--------------------------------------------------------------------------------
-- 【职责】无线广播：把快照分片发给镜像端（由 T7 每秒调用 `net.tick()`）
-- 【不做什么】不组装快照 —— 来源由入口注入（`net.setSource(api.snapshot)`），
--   这样 net 不必 require api（否则 api -> net -> api 循环）
-- 【依赖】hardware/device、shared/{config,state,models,logs}、core/scheduler
-- 【被谁用】backend/api（开关与状态）、入口 main.lua（注册 T7 并注入来源）
--
-- 【协议】一条消息 = `v3|<帧号>|<序号>|<总数>|<分片>`
--   接收端按"帧号 + 序号"拼回；缺片就整帧丢掉（下一秒又来一帧，丢一帧无所谓）。
--   所以不需要重传、不需要确认 —— 这是"显示用快照"，不是"业务数据"。
-- 【门控】总开关关 -> 任务被 scheduler 停掉（**完全不动作、不推进计时**）；
--   网卡不在位 -> tick 直接返回。
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local models    = require("shared.models")
local state     = require("shared.state")

local scheduler = require("core.scheduler")
local device    = require("backend.hardware.device")

local net       = {}

local source    = nil -- 快照生成函数（注入）
local TASK      = "broadcast"

--- 注入快照来源（入口调用一次）
-- @param fn function 返回 api.snapshot() 那种表
function net.setSource(fn)
    source = fn
end

--- 网卡/隧道是否在位
-- @return boolean
function net.available()
    return device.net() ~= nil
end

--- 广播状态（界面一行显示）
-- @return table
function net.status()
    local st = state.net
    return {
        available = net.available(),
        enabled = st.enabled == true
    }
end

--- 开关广播（同时把 T7 任务启停）
-- 只在真的变化时记一行：启动时 main 会应用一次 config 默认值，那不是用户操作。
-- @param on boolean
-- @return string 一行说明
function net.setEnabled(on)
    local before      = state.net.enabled == true
    state.net.enabled = on == true
    scheduler.setEnabled(TASK, state.net.enabled and net.available())
    local text = state.net.enabled
        and (net.available() and "无线广播：已开启" or "无线广播：已开启（但网卡不在位）")
        or "无线广播：已关闭"
    if state.net.enabled ~= before then logs.system(text) end
    return text
end

--- 切换开关
-- @return string 一行说明
function net.toggle()
    local st = state.net
    return net.setEnabled(not (st.enabled == true))
end

--- 发一段文本（分片）
-- @param text string
-- @return boolean ok
-- @return string 说明
function net.sendText(text)
    local address = device.net()
    if not address then return false, "无网卡/隧道组件" end

    local port      = CONFIG.NET.PORT
    local chunkSize = math.max(256, CONFIG.NET.CHUNK or 4000)
    local total     = math.max(1, math.ceil(#text / chunkSize))
    local frame     = (state.net.frame or 0) + 1
    state.net.frame = frame

    for i = 1, total do
        local part      = text:sub((i - 1) * chunkSize + 1, i * chunkSize)
        local message   = table.concat({ "v3", frame, i, total, part }, "|")
        local sent, err = device.invoke(address, "send", port, message, 0)
        if err then return false, "发送失败：" .. tostring(err) end
        if sent == false then return false, "发送被拒（端口/距离？）" end
    end

    return true, string.format("已广播 %d 片 / %d 字节", total, #text)
end

--- T7 任务体：一秒一次，把当前快照发给镜像端
-- 【失败不刷屏】只在"第一次失败"与"恢复"时各写一行日志
function net.tick()
    if state.net.enabled ~= true then return end
    if not source then return end

    local payload, buildErr = source()
    if not payload then
        if not state.net.warned then
            state.net.warned = true
            logs.warn("广播快照组装失败：" .. tostring(buildErr))
        end
        return
    end

    local ok, text = net.sendText(models.snapshot(payload))
    if not ok then
        if not state.net.warned then
            state.net.warned = true
            logs.warn("广播失败：" .. tostring(text))
        end
        return
    end
    if state.net.warned then
        state.net.warned = nil
        logs.system("广播已恢复")
    end
end

--- 注册 T7（入口调用；重复调用安全）
-- @return boolean 是否注册成功
function net.register()
    return scheduler.every(TASK, CONFIG.INTERVAL.BROADCAST, net.tick,
        { enabled = state.net.enabled == true and net.available() })
end

return net
