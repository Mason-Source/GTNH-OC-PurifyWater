--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/painter.lua
--
-- 定位：OC GPU 的安全绘制边界。
-- 功能：解析语义色和透明度、缓存前景/背景、处理 Unicode 宽度、截断、面板、进度条和按钮。
-- 边界：OC GPU 没有 alpha；这里的透明度仅是与 base 角色预合成的视觉效果。
--------------------------------------------------------------------------------

local unicode = require("unicode")

local Painter = {}
Painter.__index = Painter

--- 创建绑定 GPU 与主题的绘制器。
function Painter.new(gpu, theme)
    return setmetatable({
        gpu = gpu,
        theme = theme,
        fg = nil,
        bg = nil,
    }, Painter)
end

--- 更新绘制器使用的主题。
function Painter:setTheme(theme)
    self.theme = theme
end

--- 清除缓存的前景与背景色，开始一轮绘制。
function Painter:begin()
    self.fg = nil
    self.bg = nil
end

--- 在 RGB 空间中把 overlay 按 alpha 预合成到 base。
local function blend(base, overlay, alpha)
    alpha = math.max(0, math.min(1, alpha))
    local br = math.floor(base / 0x10000) % 0x100
    local bg = math.floor(base / 0x100) % 0x100
    local bb = base % 0x100
    local overlayR = math.floor(overlay / 0x10000) % 0x100
    local og = math.floor(overlay / 0x100) % 0x100
    local ob = overlay % 0x100
    local r = math.floor(br * (1 - alpha) + overlayR * alpha + 0.5)
    local g = math.floor(bg * (1 - alpha) + og * alpha + 0.5)
    local b = math.floor(bb * (1 - alpha) + ob * alpha + 0.5)
    return r * 0x10000 + g * 0x100 + b
end

--- 递归解析主题语义色，处理继承、透明度与循环引用。
local function resolve(painter, role, fallback, seen)
    role = role or fallback or "text"
    if type(role) == "number" then return role end

    local colors = painter.theme.color
    local spec = colors[role]
    if spec == nil then return colors[fallback] or colors.text end
    if type(spec) == "number" then return spec end

    seen = seen or {}
    if seen[role] then return colors[fallback] or colors.canvas end
    seen[role] = true

    if type(spec) == "string" then
        return resolve(painter, spec, fallback, seen)
    end

    if type(spec) == "table" then
        local base = resolve(painter, spec.base or spec.inherit or fallback, "canvas", seen)
        if spec.color == nil then return base end
        local alpha = tonumber(spec.alpha)
        if alpha == nil then alpha = 1 end
        if alpha <= 0 then return base end
        if alpha >= 1 then return spec.color end
        return blend(base, spec.color, alpha)
    end

    return colors[fallback] or colors.text
end

--- 把语义色角色解析为 24 位 RGB 数值。
function Painter:color(role, fallback)
    return resolve(self, role, fallback or "text")
end

--- 设置语义前景色，并跳过重复 GPU 调用。
function Painter:setForeground(role)
    local color = self:color(role, "text")
    if self.fg ~= color then
        self.gpu.setForeground(color)
        self.fg = color
    end
end

--- 设置语义背景色，并跳过重复 GPU 调用。
function Painter:setBackground(role)
    local color = self:color(role, "canvas")
    if self.bg ~= color then
        self.gpu.setBackground(color)
        self.bg = color
    end
end

--- 用指定背景角色填充矩形。
function Painter:fill(rect, role)
    self:setBackground(role or "canvas")
    self.gpu.fill(rect.x, rect.y, rect.w, rect.h, " ")
end

--- 用画布角色清除矩形区域。
function Painter:clear(rect)
    self:fill(rect, "canvas")
end

--- 返回文本的 Unicode 显示宽度。
function Painter:measure(text)
    return unicode.wlen(tostring(text or ""))
end

--- 按显示宽度截断文本并添加省略号。
function Painter:truncate(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if unicode.wlen(text) <= width then return text end

    local out = ""
    for index = 1, unicode.len(text) do
        local char = unicode.sub(text, index, index)
        if unicode.wlen(out .. char) > width - 1 then break end
        out = out .. char
    end
    return out .. "…"
end

--- 在指定位置绘制可截断的文本。
function Painter:text(x, y, text, foreground, background, width)
    text = tostring(text or "")
    if width then text = self:truncate(text, width) end
    self:setForeground(foreground or "text")
    self:setBackground(background or "canvas")
    self.gpu.set(x, y, text)
end

--- 使文本在指定宽度内右对齐。
function Painter:textRight(x, y, width, text, foreground, background)
    local value = tostring(text or "")
    return self:text(x + width - self:measure(value), y, value, foreground, background)
end

--- 绘制带边框、底色和可选标题的面板。
function Painter:panel(rect, title)
    if rect.w < 2 or rect.h < 2 then return end
    self:fill(rect, "surface")
    self:setForeground("border")
    self:setBackground("surface")

    self.gpu.set(rect.x, rect.y, "┌" .. string.rep("─", rect.w - 2) .. "┐")
    if rect.h > 2 then
        self.gpu.fill(rect.x, rect.y + 1, 1, rect.h - 2, "│")
        self.gpu.fill(rect.x + rect.w - 1, rect.y + 1, 1, rect.h - 2, "│")
    end
    self.gpu.set(rect.x, rect.y + rect.h - 1, "└" .. string.rep("─", rect.w - 2) .. "┘")

    if title and rect.w > 6 and rect.h > 2 then
        local value = " " .. title .. " "
        self:text(rect.x + 2, rect.y, value, "accent", "surface", rect.w - 4)
    end
end

--- 绘制按比例填色的单行或多行进度条。
function Painter:bar(rect, ratio, fillRole, trackRole, emptyRole)
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
    local filled = math.floor(rect.w * ratio)
    local role = filled > 0
        and (trackRole or "barTrack")
        or (emptyRole or "barEmpty")

    self:fill(rect, role)
    if filled > 0 then
        self:fill({ x = rect.x, y = rect.y, w = filled, h = rect.h }, fillRole or "barFill")
    end
end

--- 绘制带激活和禁用状态的按钮。
function Painter:button(rect, text, active, disabled, foreground, background)
    local bg = disabled and "chipDisabled"
        or (active and "chipActive" or background or "chip")
    local fg
    if disabled then
        fg = "disabled"
    elseif active then
        fg = foreground or "accent"
    else
        fg = foreground or "text"
    end
    self:fill(rect, bg)
    local padding = math.max(0, math.floor((rect.w - self:measure(text)) / 2))
    self:text(rect.x + padding, rect.y, text, fg, bg, rect.w - padding)
end

return Painter
