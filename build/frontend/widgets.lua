local unicode = require("unicode")
local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = {}
function widgets.clearArea(x, y, w, h, bgColor)
    fstate.gpu.setBackground(bgColor or theme.COLORS.BG)
    fstate.gpu.fill(x, y, w, h, " ")
end
function widgets.drawText(x, y, text, color, bgColor)
    fstate.gpu.setForeground(color or theme.COLORS.TEXT)
    fstate.gpu.setBackground(bgColor or theme.COLORS.BG)
    fstate.gpu.set(x, y, tostring(text))
end
function widgets.drawBorder(x, y, w, h, color, bgColor)
    color   = color or theme.COLORS.BORDER
    bgColor = bgColor or theme.COLORS.BG
    fstate.gpu.setForeground(color)
    fstate.gpu.setBackground(bgColor)
    fstate.gpu.set(x, y, "┌" .. string.rep("─", w - 2) .. "┐")
    for i = y + 1, y + h - 2 do
        fstate.gpu.set(x, i, "│")
        fstate.gpu.set(x + w - 1, i, "│")
    end
    fstate.gpu.set(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘")
end
function widgets.drawButton(x, y, w, text, color, bgColor, disabled)
    if disabled then
        color   = theme.COLORS.TEXT_DISABLED
        bgColor = theme.COLORS.BTN_BG_DISABLED
    end
    bgColor = bgColor or theme.COLORS.BTN_BG
    color   = color or theme.COLORS.TEXT
    fstate.gpu.setBackground(bgColor)
    fstate.gpu.setForeground(color)
    local textW   = unicode.wlen(text)
    local padding = math.max(0, math.floor((w - textW) / 2))
    local tail    = math.max(0, w - padding - textW)
    fstate.gpu.set(x, y, string.rep(" ", padding) .. text .. string.rep(" ", tail))
    fstate.gpu.setBackground(theme.COLORS.BG)
end
function widgets.drawBar(x, y, w, ratio, fillColor, bgColor)
    ratio      = math.max(0, math.min(1, ratio or 0))
    local fill = math.floor(w * ratio)
    if not bgColor then
        bgColor = (fill > 0) and theme.COLORS.BAR_BG or theme.COLORS.BAR_BG_EMPTY
    end
    fstate.gpu.setBackground(bgColor)
    fstate.gpu.fill(x, y, w, 1, " ")
    if fill > 0 then
        fstate.gpu.setBackground(fillColor or theme.COLORS.BAR_FILL)
        fstate.gpu.fill(x, y, fill, 1, " ")
    end
    fstate.gpu.setBackground(theme.COLORS.BG)
end
function widgets.textAreaRows(area, bottomMargin)
    bottomMargin = bottomMargin or 2
    local top    = area.y + 2
    local bottom = area.y + area.h - 2 - bottomMargin
    if bottom < top then bottom = top end
    return { top = top, bottom = bottom, rows = bottom - top + 1 }
end
function widgets.wrapText(text, maxWidth)
    local lines, current = {}, ""
    for i = 1, unicode.len(text) do
        local char = unicode.sub(text, i, i)
        if unicode.wlen(current .. char) > maxWidth then
            lines[#lines + 1] = current
            current = char
        else
            current = current .. char
        end
    end
    if unicode.wlen(current) > 0 then lines[#lines + 1] = current end
    return lines
end
function widgets.centerX(x, w, text)
    return x + math.floor((w - unicode.wlen(text)) / 2)
end
function widgets.drawCenteredTip(area, text, color)
    widgets.drawText(widgets.centerX(area.x, area.w, text),
        area.y + math.floor(area.h / 2), text, color or theme.COLORS.TEXT_YELLOW)
end
function widgets.drawTextRight(x, w, y, text, color, bgColor)
    local startX = x + w - unicode.wlen(text)
    widgets.drawText(startX, y, text, color, bgColor)
    return startX
end
return widgets
