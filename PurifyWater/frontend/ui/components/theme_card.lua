--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/theme_card.lua
--
-- 定位：主题选择卡片组件。
-- 功能：列出注册主题并产生主题切换动作。
-- 边界：只发动作，不持久化主题。
--------------------------------------------------------------------------------

local Component = require("frontend.ui.base")
local theme_registry = require("frontend.theme.registry")

local ThemeCard = {}

--- 创建主题选择卡片组件。
function ThemeCard.new()
    local self = Component.new("theme_card", {})
    self.fingerprint = ThemeCard.fingerprint
    self.render = ThemeCard.render
    return self
end

--- 生成主题和尺寸的渲染指纹。
function ThemeCard:fingerprint(context)
    return table.concat({
        self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h,
        context.themeId,
    }, "\x1f")
end

--- 绘制全部主题按钮。
function ThemeCard:render(context)
    local p = context.painter
    local r = self.rect
    p:panel(r, "主题")
    if r.h < 3 then return end

    local themes = theme_registry.list()
    local buttonW = 10
    local gap = 2
    local totalW = #themes * buttonW + math.max(0, #themes - 1) * gap
    local x = r.x + 2 + math.max(0, math.floor((r.w - 4 - totalW) / 2))
    local y = r.y + 2

    for _, item in ipairs(themes) do
        local active = item.id == context.themeId
        local rect = { x = x, y = y, w = buttonW, h = 1 }
        p:button(rect, item.label, active, false, active and "success" or "text")
        context:hit({ type = "theme", value = item.id }, rect)
        x = x + buttonW + gap
    end
end

return ThemeCard