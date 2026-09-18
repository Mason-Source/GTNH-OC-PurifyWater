local unicode = require("unicode")
local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local tabbar  = {}
local TABS    = {
    { key = "overview", label = "总览" },
    { key = "config", label = "配置" }
}
local HINT    = "X 启停 · P 优先级 · R 刷新 · T 切页 · Q 退出 · 阈值在配置页"
function tabbar.draw()
    local area = fstate.areas.tabBar
    widgets.clearArea(area.x, area.y, area.w, area.h, theme.COLORS.BTN_BG)
    fstate.tabs = {}
    local x = area.x + 2
    for _, tab in ipairs(TABS) do
        local text    = " " .. tab.label .. " "
        local width   = unicode.wlen(text)
        local current = (fstate.currentTab == tab.key)
        widgets.drawText(x, area.y, text,
            current and theme.COLORS.TEXT_CYAN or theme.COLORS.TEXT_DISABLED,
            current and theme.COLORS.BTN_BG_HOVER or theme.COLORS.BTN_BG)
        fstate.tabs[tab.key] = { x = x, y = area.y, w = width, h = 1 }
        x = x + width + 2
    end
    local hint = HINT
    if unicode.wlen(hint) > area.w - x - 2 then
        hint = "X 启停 · T 切页 · Q 退出"
    end
    local startX = area.x + area.w - 2 - unicode.wlen(hint)
    widgets.drawText(startX, area.y, hint, theme.COLORS.TEXT_DISABLED, theme.COLORS.BTN_BG)
end
function tabbar.fingerprint()
    return tostring(fstate.currentTab)
end
return tabbar
