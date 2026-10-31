local Component = require("frontend.ui.base")
local Settings = {}

function Settings.new()
    local self = Component.new("settings", {})
    self.fingerprint = Settings.fingerprint
    self.render = Settings.render
    return self
end

function Settings:fingerprint(context)
    local s = self.props.settings or {}
    return table.concat({
        self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h, context.themeId,
        tostring(s.autostart), tostring(s.autostartStale), tostring(s.autostartPath),
    }, "\x1f")
end

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
