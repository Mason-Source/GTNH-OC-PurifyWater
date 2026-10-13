local unicode = require("unicode")
local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local tabbar  = {}
local TABS    = {
    { key = "overview", label = "总览" },
    { key = "config", label = "配置" }
}
local HINT    = "X 启停 · R 刷新 · T 切页 · Q 退出"
function tabbar.draw()
    local area = fstate.areas.tabBar
    local ro   = fstate.readOnly == true
    widgets.clearArea(area.x, area.y, area.w, area.h, theme.COLORS.BTN_BG)
    fstate.tabs = {}
    local x = area.x + 2
    for _, tab in ipairs(TABS) do
        local text    = " " .. tab.label .. " "
        local width   = unicode.wlen(text)
        local current = (fstate.currentTab == tab.key)
        local usable  = (not ro) or (tab.key == "overview")
        widgets.drawText(x, area.y, text,
            (current and usable) and theme.COLORS.TEXT_CYAN or theme.COLORS.TEXT_DISABLED,
            (current and usable) and theme.COLORS.BTN_BG_HOVER or theme.COLORS.BTN_BG)
        if usable then
            fstate.tabs[tab.key] = { x = x, y = area.y, w = width, h = 1 }
        end
        x = x + width + 2
    end
    if ro then return end
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
