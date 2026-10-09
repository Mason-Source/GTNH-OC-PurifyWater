--------------------------------------------------------------------------------
-- frontend/panels/settings.lua
--------------------------------------------------------------------------------
-- 【职责】配置页的「运行设置」卡片：子项「开机自启动」（勾选框）+ 一行说明
-- 【不做什么】不碰文件（.shrc 的读写都在 backend/store/autostart）、不发命令
--   （点这一行由 frontend/input 发 autostart_toggle）、不画别的卡片
-- 【依赖】frontend/{state,theme,widgets}
-- 【被谁用】frontend/render（配置页的面板表）
--
-- 【显示的是真源】勾选与否来自 api.read.system().autostart —— 也就是 .shrc 里那段块在不在、
--   指不指向当前应用目录；stale = 块在但指向别处（只提示，点勾选才改写成当前路径）。
-- 【热区】整行都是热区（点哪儿都算点这一项）；说明行不登记，免得读个字就把开关碰反。
--------------------------------------------------------------------------------

local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")

local settings = {}

function settings.draw(data)
    local area = fstate.areas.settings
    fstate.autostartRow = nil
    if not area or area.h < 1 then return end

    widgets.clearArea(area.x, area.y, area.w, area.h)
    if area.h < 3 then return end -- 屏幕太矮：这张卡画不下就不画（别糊到邻块）

    local sys   = (data and data.system) or {}
    local on    = sys.autostart == true
    local stale = sys.autostartStale == true
    local shrc  = tostring(sys.autostartPath or ".shrc")

    widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(stale))
    widgets.drawText(area.x + 2, area.y + 1, "运行设置", theme.COLORS.TEXT_CYAN)
    if area.h < 4 then return end -- 再矮就连子项都画不下，只留标题

    -- 子项行：勾选框 + 名称；整行热区
    local rowY = area.y + 2
    fstate.autostartRow = { x = area.x + 2, y = rowY, w = area.w - 4, h = 1 }
    widgets.drawText(area.x + 2, rowY, on and "[√] 开机自启动" or "[  ] 开机自启动",
        on and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED)
    if area.h < 5 then return end

    -- 说明行：跟随状态（未勾选 / 已勾选 / 指向别处）
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

--- 指纹：位置尺寸 + 勾选 / stale / .shrc 路径（面板级指纹必须盖住这里画的每一样输入）
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
