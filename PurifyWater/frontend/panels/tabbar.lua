--------------------------------------------------------------------------------
-- frontend/panels/tabbar.lua
--------------------------------------------------------------------------------
-- 【职责】顶部页签栏：`总览` / `配置` + 右侧一行操作提示
-- 【依赖】frontend/{state,theme,widgets}
-- 【被谁用】frontend/render
--
-- 快捷键提示放页签行右侧（顶部标题栏已删，右侧本就空着）。
-- 命令执行结果不弹提示，只进系统日志；阈值改用配置页虚拟键盘、物理键盘不进输入框，
--   所以这里也没有"正在输入…"那种编辑态提示。
--------------------------------------------------------------------------------

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
    -- 页签行是"一条栏"：整行铺底色，不画边框（省一行给内容）
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

    -- 右侧：快捷键提示（太窄就退成更短的一行）
    local hint = HINT
    if unicode.wlen(hint) > area.w - x - 2 then
        hint = "X 启停 · T 切页 · Q 退出"
    end
    local startX = area.x + area.w - 2 - unicode.wlen(hint)
    widgets.drawText(startX, area.y, hint, theme.COLORS.TEXT_DISABLED, theme.COLORS.BTN_BG)
end

--- 指纹：当前页（页签高亮与提示语都由它决定）
function tabbar.fingerprint()
    return tostring(fstate.currentTab)
end

return tabbar
