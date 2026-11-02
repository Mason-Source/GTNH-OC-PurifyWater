--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/settings.lua
--
-- 定位：运行设置卡片组件。
-- 功能：显示开机自启状态与路径提示，并产生自启切换动作。
-- 边界：不直接修改 .shrc 或设置状态。
--------------------------------------------------------------------------------

local Component = require("frontend.ui.base")
local Settings = {}

--- 创建运行设置卡片组件。
function Settings.new()
    local self = Component.new("settings", {})
    self.fingerprint = Settings.fingerprint
    self.render = Settings.render
    return self
end

--- 生成自启状态和尺寸的渲染指纹。
function Settings:fingerprint(context)
    local s = self.props.settings or {}
    return table.concat({
        self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h, context.themeId,
        tostring(s.autostart), tostring(s.autostartStale), tostring(s.autostartPath),
    }, "\x1f")
end

--- 绘制开机自启开关与路径提示。
function Settings:render(context)
    local p = context.painter
    local r = self.rect
    local s = self.props.settings or {}
    p:panel(r, "运行设置")
    if r.h < 3 then return end

    local row = { x = r.x + 2, y = r.y + 2, w = r.w - 4, h = 1 }
    p:text(row.x, row.y, s.autostart and "[√] 开机自启动" or "[ ] 开机自启动",
        s.autostart and "success" or "disabled", "surface", row.w)
    context:hit({ type = "command", name = "autostart_toggle" }, row)

    if r.h >= 5 then
        local hint = s.autostartStale and "自启路径不一致" or (s.autostart and "已写入启动配置" or "开机需手动运行")
        p:text(r.x + 6, r.y + 3, hint, s.autostartStale and "danger" or "muted", "surface", r.w - 8)
    end
end

return Settings
