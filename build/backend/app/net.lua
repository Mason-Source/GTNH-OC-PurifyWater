local CONFIG   = require("shared.config")
local logs     = require("shared.logs")
local models   = require("shared.models")
local state    = require("shared.state")
local settings = require("backend.store.settings")
local net      = require("backend.hardware.net")
local app      = {}
function app.loadSettings(bootSettings)
    bootSettings = bootSettings or {}
    local on = models.bool(bootSettings[CONFIG.NET.ENABLED_KEY], CONFIG.NET.ENABLED == true)
    net.setEnabled(on)
    if bootSettings[CONFIG.NET.ENABLED_KEY] == nil then
        settings.set(CONFIG.NET.ENABLED_KEY, on)
    end
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
function app.toggle()
    local on   = not (state.read.net().enabled == true)
    local text = net.setEnabled(on)
    local ok   = settings.set(CONFIG.NET.ENABLED_KEY, on)
    if not ok then logs.warn("广播开关保存失败（重启回到上次保存的值）") end
    return text
end
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
