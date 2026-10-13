--------------------------------------------------------------------------------
-- backend/hardware/net.lua
--------------------------------------------------------------------------------
-- 【职责】无线广播：把快照分片发给镜像端（由 T7 每秒调用 `net.tick()`）
-- 【不做什么】不组装快照（来源由入口注入，避免循环依赖）
-- 【依赖】hardware/device、shared/{config,state,models,logs}、core/scheduler
-- 【被谁用】backend/api（开关与状态）、入口 main.lua（注册 T7 并注入来源）
--
-- 消息 = v3|帧号|序号|总数|分片；缺片整帧丢，不重传不确认（显示用快照）。
-- 门控：总开关关则任务停（不推进计时）；网卡不在位 tick 直接返回。
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
    local st = state.read.net()
    return {
        available = net.available(),
        enabled = st.enabled == true,
        strength = state.read.netStrength() -- 配置值（方块）；实际生效值以卡为准
    }
end

--- 开关广播（同时把 T7 任务启停）
-- 只在真的变化时记一行：开机读回上次保存的开关（关→开）也会写一行，方便确认广播状态。
-- @param on boolean
-- @return string 一行说明
function net.setEnabled(on)
    local before      = state.read.net().enabled == true
    state.write.netSetEnabled(on == true)
    -- 任务只按总开关启停；网卡在不在位交给 tick 顶部早退（插卡后自动恢复）
    scheduler.setEnabled(TASK, state.read.net().enabled)
    local text = state.read.net().enabled
        and (net.available() and "无线广播：已开启" or "无线广播：已开启（网卡不在位，不发送）")
        or "无线广播：已关闭"
    if state.read.net().enabled ~= before then logs.system(text) end
    return text
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
    local frame     = (state.read.net().frame or 0) + 1
    state.write.netSetFrame(frame)

    for i = 1, total do
        local part      = text:sub((i - 1) * chunkSize + 1, i * chunkSize)
        local message   = table.concat({ "v3", frame, i, total, part }, "|")
        -- 【OC 1.8 的 modem API】send(address, port, ...) 第一参是目标地址，老式 send(port, ...) 已不存在；
        --   快照是"谁在监听这个端口谁就收" —— 对应 broadcast(port, ...)
        local sent, err, reason = device.invoke(address, "broadcast", port, message)
        if err then return false, "发送失败：" .. tostring(err) end
        if sent == false or (sent == nil and reason) then
            return false, "发送被拒：" .. tostring(reason or "端口/距离")
        end
    end

    return true, string.format("已广播 %d 片 / %d 字节", total, #text)
end

-- 无线范围：把配置值下发给"当前正在用的那张无线卡"（同一张卡 + 同一个值只下发一次）
-- 有线卡/隧道没有 isWireless/setStrength，跳过；卡会把超过自己上限的值夹回来。
local strengthFor, strengthSent = nil, nil

--- 下发一次（无线卡才行）
-- @param address string|nil 网卡地址
-- @param value number 目标范围（方块）
-- @return number|nil 实际生效值（卡夹取后）；nil = 没下发
-- @return string|nil 原因："无卡" / "有线卡" / 组件错误文本
local function pushStrength(address, value)
    if not address then return nil, "无卡" end
    if device.invoke(address, "isWireless") ~= true then return nil, "有线卡" end
    local applied, err = device.invoke(address, "setStrength", value)
    if err then return nil, tostring(err) end
    strengthFor, strengthSent = address, value
    return tonumber(applied) or value
end

--- T7 每拍：把配置的无线范围同步到当前网卡（值或卡没变就不重复下发）
local function syncStrength()
    local address = device.net()
    if not address then strengthFor, strengthSent = nil, nil return end
    local value = state.read.netStrength()
    if strengthFor == address and strengthSent == value then return end
    local applied, why = pushStrength(address, value)
    if not applied then
        -- 记下这次尝试：有线卡/下发失败不每拍重试（值或卡变了才会再试），日志也只报一次
        strengthFor, strengthSent = address, value
        if why ~= "有线卡" then logs.warn("设置无线范围失败：" .. tostring(why)) end
        return
    end
    -- 换卡后配置值超出新卡上限：报一次（用户设置那条由 app/net 写）
    if applied ~= value then
        logs.system(string.format("无线范围 %d 超出卡上限，已按 %d 生效", value, applied))
    end
end

-- 发射计数：曲线降频（每 5 拍带一次；第 1 拍就带，镜像端尽快有图）
local tickCount = 0

--- 立即设置无线范围（界面命令用；卡会把超限值夹回来）
-- @param value number 目标范围（方块；0 = 不发无线）
-- @return number|nil 实际生效值；nil = 没下发
-- @return string|nil 原因："无卡" / "有线卡" / 组件错误文本
function net.setStrength(value)
    return pushStrength(device.net(), value)
end

--- T7 任务体：一秒一次，把当前快照发给镜像端
-- 失败只在第一次与恢复时各写一行
function net.tick()
    if state.read.net().enabled ~= true then return end
    if not source then return end
    if not net.available() then return end -- 网卡不在位：不组包、不发送；插卡后自动恢复

    syncStrength()
    tickCount = tickCount + 1
    local payload, buildErr = source({ chart = (tickCount % 5 == 1) })
    if not payload then
        if not state.read.net().warned then
            state.write.netSetWarned(true)
            logs.warn("广播快照组装失败：" .. tostring(buildErr))
        end
        return
    end

    local ok, text = net.sendText(models.snapshot(payload))
    if not ok then
        if not state.read.net().warned then
            state.write.netSetWarned(true)
            logs.warn("广播失败：" .. tostring(text))
        end
        return
    end
    if state.read.net().warned then
        state.write.netSetWarned(nil)
        logs.system("广播已恢复")
    end
end

--- 注册 T7（入口调用；重复调用安全）
-- @return boolean 是否注册成功
function net.register()
    return scheduler.every(TASK, CONFIG.INTERVAL.BROADCAST, net.tick,
        { enabled = state.read.net().enabled == true })
end

return net
