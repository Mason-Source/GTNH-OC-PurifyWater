--------------------------------------------------------------------------------
-- backend/app/net.lua
--------------------------------------------------------------------------------
-- 【职责】无线广播用例：开关 + 无线范围（改内存 + 写 settings.txt + 下发网卡）
-- 【不做什么】不组包、不发消息（hardware/net）、不算功率
-- 【依赖】shared/{config,logs,models,state}、store/settings、hardware/net
-- 【被谁用】backend/api（net_toggle / net_strength_set）、main.lua（开机读回 loadSettings）
--------------------------------------------------------------------------------

local CONFIG   = require("shared.config")
local logs     = require("shared.logs")
local models   = require("shared.models")
local state    = require("shared.state")

local settings = require("backend.store.settings")
local net      = require("backend.hardware.net")

local app      = {}

--- 开机读回：开关与范围都从 settings.txt 恢复（缺键补写默认值）
-- 【时序】main 在 net.register() 之前调用：setEnabled 先只改内存，register 按内存值注册
-- @param bootSettings table|nil settings.load() 的结果
function app.loadSettings(bootSettings)
    bootSettings = bootSettings or {}

    local on = models.bool(bootSettings[CONFIG.NET.ENABLED_KEY], CONFIG.NET.ENABLED == true)
    net.setEnabled(on) -- 日志只在真变化时写（这里是"上次开着 → 开机保持"）
    if bootSettings[CONFIG.NET.ENABLED_KEY] == nil then
        settings.set(CONFIG.NET.ENABLED_KEY, on)
    end

    -- 范围：手改配置也要能兜住，先夹到兜底上限（真值以网卡夹取为准）
    local strength = tonumber(bootSettings[CONFIG.NET.STRENGTH_KEY])
    if not strength or strength ~= math.floor(strength) or strength < 0 then
        strength = CONFIG.NET.STRENGTH
    end
    if strength > CONFIG.NET.STRENGTH_MAX then strength = CONFIG.NET.STRENGTH_MAX end
    state.write.netSetStrength(strength)
    if bootSettings[CONFIG.NET.STRENGTH_KEY] == nil then
        settings.set(CONFIG.NET.STRENGTH_KEY, strength)
    end
end

--- 切换广播开关：改内存（T7 任务启停）+ 落盘，重启保持
-- @return string 一行说明
function app.toggle()
    local on   = not (state.read.net().enabled == true)
    local text = net.setEnabled(on) -- 日志由这里写（含"网卡不在位"提示）
    local ok   = settings.set(CONFIG.NET.ENABLED_KEY, on)
    if not ok then logs.warn("广播开关保存失败（重启回到上次保存的值）") end
    return text
end

--- 设置无线范围（方块）：**输入被网卡夹取**，存"实际生效值"
-- 无线卡：以卡返回的值为准（T1 上限 16 / T2 上限 400 都由卡决定）
-- 有线卡：没有无线发射，存 0；无卡：先存输入值，插卡后由 T7 同步再夹
-- @param value number|string 0 以上整数
-- @return boolean ok
-- @return string 说明（成功为空串）
function app.setStrength(value)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < 0 then
        return false, "无线范围需为 0 以上的整数（方块）"
    end

    local applied, why = net.setStrength(value)
    if not applied then
        if why == "有线卡" then
            applied = 0
        else
            applied = value
        end
    end

    local note = ""
    if applied ~= value then
        note = string.format("（输入 %d 被卡钳制）", value)
    elseif why == "无卡" then
        note = "（网卡不在位，插卡后生效）"
    end

    state.write.netSetStrength(applied)
    local ok = settings.set(CONFIG.NET.STRENGTH_KEY, applied)
    logs.system(string.format("无线范围：%d 方块%s%s", applied, note,
        ok and "" or "（保存失败，重启回到上次保存的值）"))
    return true, ""
end

return app
