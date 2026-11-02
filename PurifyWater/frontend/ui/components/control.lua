--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/control.lua
--
-- 定位：总览页控制面板组件。
-- 功能：展示系统摘要并绘制启动、模式、刷新、广播和退出按钮。
-- 边界：只发出 button 动作，不直接执行业务命令。
--------------------------------------------------------------------------------

local Component = require("frontend.ui.base")
local Control = {}

--- 创建总览页控制面板组件。
function Control.new()
    local self = Component.new("control", { rows = {}, buttons = {} })
    self.fingerprint = Control.fingerprint
    self.render = Control.render
    return self
end

--- 生成控制面板内容与尺寸的渲染指纹。
function Control:fingerprint(context)
    local parts = { self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h, context.themeId }
    for _, row in ipairs(self.props.rows or {}) do
        parts[#parts + 1] = table.concat({ row.label, row.value, row.role }, ":")
    end
    for _, key in ipairs({ "system", "mode", "subparam", "refresh", "net", "quit" }) do
        local button = (self.props.buttons or {})[key] or {}
        parts[#parts + 1] = table.concat({
            key, tostring(button.label), tostring(button.disabled), tostring(button.role),
            tostring(button.active), tostring(button.background),
        }, ":")
    end
    return table.concat(parts, "\x1f")
end

local function drawButton(component, context, key, rect)
    local button = (component.props.buttons or {})[key]
    if not button or rect.w < 2 then return end
    local p = context.painter
    local disabled = button.disabled == true or (context.readOnly and key ~= "quit")
    p:button(rect, button.label or key, button.active == true, disabled, button.role, button.background)
    if not disabled then
        context:hit({ type = "command", name = button.action }, rect)
    end
end

local function columns(area, weights)
    local out, total = {}, 0
    for _, weight in ipairs(weights) do total = total + weight end
    local x, left = area.x, area.w
    for index, weight in ipairs(weights) do
        local width = (index == #weights) and left or math.floor(area.w * weight / total)
        out[index] = { x = x, w = width }
        x = x + width
        left = left - width
    end
    return out
end

--- 绘制系统摘要和操作按钮。
function Control:render(context)
    local p = context.painter
    local r = self.rect
    local rows = self.props.rows or {}
    p:panel(r)
    p:text(r.x + 2, r.y + 1, "控制面板", "accent", "surface", math.max(1, r.w - 4))

    local cols = columns({ x = r.x + 2, w = math.max(1, r.w - 4) }, { 0.34, 0.66 })
    local maxRows = math.max(0, r.h - 8)
    for index = 1, math.min(#rows, maxRows) do
        local row = rows[index]
        local y = r.y + 1 + index
        p:text(cols[1].x, y, row.label, "text", "surface", cols[1].w)
        p:text(cols[2].x, y, row.value, row.role or "text", "surface", math.max(1, cols[2].w - 1))
    end

    local step = 2
    local startY = r.y + r.h - 2 - 8
    if startY <= r.y + 1 + math.min(#rows, maxRows) then
        step = 1
        startY = r.y + r.h - 2 - 4
    end
    local x = r.x + 3
    local fullW = math.max(2, r.w - 6)
    local halfW = math.floor((fullW - 1) / 2)

    drawButton(self, context, "system", { x = x, y = startY, w = fullW, h = 1 })
    drawButton(self, context, "mode", { x = x, y = startY + step, w = halfW, h = 1 })
    drawButton(self, context, "subparam",
        { x = x + halfW + 1, y = startY + step, w = fullW - halfW - 1, h = 1 })
    drawButton(self, context, "refresh", { x = x, y = startY + step * 2, w = fullW, h = 1 })
    drawButton(self, context, "net", { x = x, y = startY + step * 3, w = fullW, h = 1 })
    drawButton(self, context, "quit", { x = x, y = startY + step * 4, w = fullW, h = 1 })
end

return Control
