--------------------------------------------------------------------------------
-- frontend/widgets.lua
--------------------------------------------------------------------------------
-- 【职责】绘制原语：清区 / 边框 / 文本 / 按钮 / 进度条 / 折行 / 行位预算
-- 【不做什么】不含任何业务判断（颜色与文案由主题给、数据由 viewmodel 给）
-- 【依赖】unicode、frontend/{state,theme}
-- 【被谁用】frontend/panels/*、frontend/charts
--
-- 【来源】v2 的排版工具（实机用过）
-- 中文是宽字符：一切宽度都用 unicode.wlen，不能用 #text
--------------------------------------------------------------------------------

local unicode = require("unicode")

local fstate  = require("frontend.state")
local theme   = require("frontend.theme")

local widgets = {}

--------------------------------------------------------------------------------
-- 基础
--------------------------------------------------------------------------------

--- 用背景色清空一块矩形
-- @param x, y, w, h number
-- @param bgColor number|nil
function widgets.clearArea(x, y, w, h, bgColor)
    fstate.gpu.setBackground(bgColor or theme.COLORS.BG)
    fstate.gpu.fill(x, y, w, h, " ")
end

--- 写一行文本
-- @param x, y number
-- @param text string
-- @param color number|nil
-- @param bgColor number|nil
function widgets.drawText(x, y, text, color, bgColor)
    fstate.gpu.setForeground(color or theme.COLORS.TEXT)
    fstate.gpu.setBackground(bgColor or theme.COLORS.BG)
    fstate.gpu.set(x, y, tostring(text))
end

--- 画矩形边框
-- @param x, y, w, h number
-- @param color number|nil
-- @param bgColor number|nil
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

--- 画一个按钮（文本居中；宽度按显示宽度算）
-- @param x, y, w number
-- @param text string
-- @param color number|nil
-- @param bgColor number|nil
-- @param disabled boolean|nil 禁用形态（暗色）
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

--- 画一条进度条（同行，宽度 w）
-- @param x, y, w number
-- @param ratio number 0~1
-- @param fillColor number|nil 不传 = theme.COLORS.BAR_FILL（绿）
-- @param bgColor number|nil 不传 = 按下面规则自动选
-- 底色规则：填了东西 = 浅绿；一格都没填上 = 浅红。判据用**实际填充格数**而不是 ratio==0
--   （水量极少但填不满一格时看到的就是空条，应该跟空条同色）。
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

--------------------------------------------------------------------------------
-- 行位预算（列表型面板共用，**单一来源**）
--------------------------------------------------------------------------------
-- 面板 h 行从上到下：
--   area.y              上边框
--   area.y + 1          标题
--   area.y + 2 … bottom 正文
--   bottom + 1 … h - 2  底部留白
--   area.y + h - 1      下边框
-- v2 把缓冲行数与正文行数写在两处，结果"最新一行永远看不见"；现在两边都调这里。
-- @param area table { y = , h = }
-- @param bottomMargin number|nil 默认 2
-- @return table { top = , bottom = , rows = }
function widgets.textAreaRows(area, bottomMargin)
    bottomMargin = bottomMargin or 2
    local top    = area.y + 2
    local bottom = area.y + area.h - 2 - bottomMargin
    if bottom < top then bottom = top end
    return { top = top, bottom = bottom, rows = bottom - top + 1 }
end

--------------------------------------------------------------------------------
-- 文本处理
--------------------------------------------------------------------------------

--- 按显示宽度折行（中文占 2 列）
-- @param text string
-- @param maxWidth number
-- @return table 行数组
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

--- 居中显示的起始 x
-- @param x, w number
-- @param text string
-- @return number
function widgets.centerX(x, w, text)
    return x + math.floor((w - unicode.wlen(text)) / 2)
end

--- 在区域中央写一行提示（图表"数据采集中…"）
-- @param area table
-- @param text string
-- @param color number|nil
function widgets.drawCenteredTip(area, text, color)
    widgets.drawText(widgets.centerX(area.x, area.w, text),
        area.y + math.floor(area.h / 2), text, color or theme.COLORS.TEXT_YELLOW)
end

--- 右侧对齐写文本（返回起始 x，交给面板自己画多段时用）
-- @param x, w number 容器
-- @param y number
-- @param text string
-- @param color number|nil
-- @param bgColor number|nil
-- @return number 起始 x
function widgets.drawTextRight(x, w, y, text, color, bgColor)
    local startX = x + w - unicode.wlen(text)
    widgets.drawText(startX, y, text, color, bgColor)
    return startX
end

return widgets
