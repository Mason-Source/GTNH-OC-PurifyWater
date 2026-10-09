local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local settings = {}
function settings.draw(data)
    local area = fstate.areas.settings
    fstate.autostartRow = nil
    if not area or area.h < 1 then return end
    widgets.clearArea(area.x, area.y, area.w, area.h)
    if area.h < 3 then return end
    local sys   = (data and data.system) or {}
    local on    = sys.autostart == true
    local stale = sys.autostartStale == true
    local shrc  = tostring(sys.autostartPath or ".shrc")
    widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(stale))
    widgets.drawText(area.x + 2, area.y + 1, "运行设置", theme.COLORS.TEXT_CYAN)
    if area.h < 4 then return end
    local rowY = area.y + 2
    fstate.autostartRow = { x = area.x + 2, y = rowY, w = area.w - 4, h = 1 }
    widgets.drawText(area.x + 2, rowY, on and "[√] 开机自启动" or "[  ] 开机自启动",
        on and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED)
    if area.h < 5 then return end
    local hint, color
    if stale then
        hint  = string.format("检测到 %s 里的自启指向其它路径（勾选可更新为当前路径）", shrc)
        color = theme.COLORS.TEXT_RED
    elseif on then
        hint  = string.format("电脑开机后自动运行本程序（已写入 %s，下次开机生效）", shrc)
        color = theme.COLORS.TEXT_DISABLED
    else
        hint  = string.format("电脑开机后需手动运行本程序（勾选后写入 %s，下次开机生效）", shrc)
        color = theme.COLORS.TEXT_DISABLED
    end
    widgets.drawText(area.x + 6, area.y + 3, hint, color)
end
function settings.fingerprint(data)
    local area = fstate.areas.settings
    local sys  = (data and data.system) or {}
    return table.concat({
        tostring(area and area.x or 0), tostring(area and area.y or 0),
        tostring(area and area.w or 0), tostring(area and area.h or 0),
        tostring(sys.autostart), tostring(sys.autostartStale), tostring(sys.autostartPath)
    }, "\x1f")
end
return settings
