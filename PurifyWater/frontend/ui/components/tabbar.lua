--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/tabbar.lua
--
-- 定位：页面页签与快捷键提示组件。
-- 功能：绘制总览/配置页签，并在只读模式下隐藏配置入口。
-- 边界：不切换页面；页面切换由 input 路由。
--------------------------------------------------------------------------------

local Component = require("frontend.ui.base")
local TabBar = {}

--- 创建页面页签组件。
function TabBar.new()
    local self = Component.new("tabbar", { page = "overview" })
    self.fingerprint = TabBar.fingerprint
    self.render = TabBar.render
    return self
end

--- 生成当前页、只读模式和尺寸的渲染指纹。
function TabBar:fingerprint(context)
    return table.concat({
        self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h,
        context.themeId, tostring(self.props.page), tostring(context.readOnly),
    }, "\x1f")
end

--- 绘制页签与快捷键提示。
function TabBar:render(context)
    local p = context.painter
    local r = self.rect
    local page = self.props.page or "overview"
    p:fill(r, "menu")

    local x = r.x + 1
    local tabs = { { key = "overview", label = "总览" } }
    if not context.readOnly then tabs[#tabs + 1] = { key = "config", label = "配置" } end
    for _, tab in ipairs(tabs) do
        local text = " " .. tab.label .. " "
        local width = p:measure(text)
        local active = page == tab.key
        local chip = { x = x, y = r.y, w = width, h = 1 }
        p:button(chip, text, false, false,
            active and "menuChipActiveText" or "menuChipText",
            active and "menuChipActive" or "menuChip")
        context:hit({ type = "page", page = tab.key }, chip)
        x = x + width + 1
    end

    local hint = context.readOnly and "镜像端 · 只读 · Q 退出" or "X 启停 · R 刷新 · T 切页 · Q 退出"
    local hintW = p:measure(hint)
    if x + 2 + hintW <= r.x + r.w then
        p:textRight(r.x, r.y, r.w - 1, hint, "menuMuted", "menu")
    end
end

return TabBar
