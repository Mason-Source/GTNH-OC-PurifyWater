-- V1 风格水量监视：全部=变化量柱状图，Tn=单级水位曲线。
local Component = require("frontend.ui.base")
local constants = require("shared.constants")
local util = require("shared.util")
local Chart = {}

local GUTTER = 7

local function gameHoursText(realMinutes)
    local hours = math.floor(util.realSecondsToGameHours((tonumber(realMinutes) or 0) * 60) + 0.5)
    return math.max(1, hours)
end

function Chart.new()
    local self = Component.new("chart", { history = { count = 0, values = {} } })
    self.fingerprint = Chart.fingerprint
    self.render = Chart.render
    return self
end

function Chart:fingerprint(context)
    local history = self.props.history or {}
    local values = history.values or {}
    local parts = {
        self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h,
        context.themeId, tostring(context.ui.chartLevel or 0),
        tostring(history.count or 0), tostring(history.windowMinutes or 40),
    }
    for level = 1, constants.LEVEL_COUNT do
        local series = values[level] or {}
        parts[#parts + 1] = tostring(#series) .. ":" .. tostring(series[1] or "")
            .. ":" .. tostring(series[#series] or "")
    end
    return table.concat(parts, "\x1f")
end

local function chips(_, context, r, windowMinutes)
    local p = context.painter
    local selected = context.ui.chartLevel or 0
    local x = r.x + 2
    local labels = { "全部", "T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8" }
    for level = 0, 8 do
        local text = " " .. labels[level + 1] .. " "
        local width = p:measure(text)
        local rect = { x = x, y = r.y + 1, w = width, h = 1 }
        local active = selected == level
        local bg = active and "chartChipActive" or "chartChip"
        local fg = active and "text" or (level == 0 and "accent" or context.theme.series[level])
        p:fill(rect, bg)
        p:text(rect.x + 1, rect.y, labels[level + 1], fg, bg, width - 1)
        context:hit({ type = "chart_level", level = level }, rect)
        x = x + width + 1
    end
    local windowText = string.format("近 %d 游戏时", gameHoursText(windowMinutes))
    p:textRight(r.x, r.y + 1, r.w - 2, windowText, "disabled", "surface")
end

local function metrics(r)
    local x0 = r.x + 2 + 1 + GUTTER
    local y0 = r.y + 3
    local w = r.w - 2 * 2 - 2 - GUTTER
    local h = r.h - 5
    return x0, y0, w, h
end

local function shortNumber(value, width)
    local text = util.formatShortNumber(tonumber(value) or 0)
    width = math.max(1, math.floor(width or 1))
    if #text <= width then return text end
    local short = text:gsub("%.%d+", "")
    return #short <= width and short or (short:sub(1, math.max(1, width - 1)) .. "…")
end


local function gutter(_, context, r, y, value, role)
    local p = context.painter
    p:textRight(r.x + 1, y, GUTTER, shortNumber(value, GUTTER), role or "warning", "surface")
end

local function grid(_, context, x0, y0, w, h)
    local p = context.painter
    p:setBackground("surface")
    p:setForeground("chartGrid")
    for row = 1, 3 do
        local y = y0 + math.floor(h * row / 4)
        p.gpu.fill(x0, y, w, 1, "·")
    end

    p:setForeground("chartAxis")
    p.gpu.fill(x0 - 1, y0, 1, h, "│")
    p.gpu.fill(x0, y0 + h - 1, w, 1, "─")
    p.gpu.set(x0 - 1, y0 + h - 1, "└")
end

local function labels(_, context, x0, y0, w, h, count, interval)
    local p = context.painter
    if count < 2 then return end
    local points = { 1, math.floor(count / 2) + 1, count }
    for _, index in ipairs(points) do
        local x = x0 + math.floor((index - 1) / (count - 1) * (w - 1))
        local text
        if index == count then
            text = "现在"
        else
            local hours = math.floor(util.realSecondsToGameHours((count - index) * interval) + 0.5)
            text = hours < 1 and "刚刚" or string.format("-%d 游戏时", hours)
        end
        local tx = x - math.floor(p:measure(text) / 2)
        tx = math.max(x0, math.min(tx, x0 + w - p:measure(text)))
        p:text(tx, y0 + h, text, "muted", "surface", w)
    end
end

local function drawSeries(self, context, r, history, level)
    local p = context.painter
    local x0, y0, w, h = metrics(r)
    if w < 8 or h < 4 then return end
    local values = (history.values or {})[level] or {}
    local count = #values
    local windowMinutes = tonumber(history.windowMinutes) or 40
    local label = constants.levelLabel(level)
    p:text(x0, y0 - 1, string.format("近 %d 游戏时 %s 水量曲线", gameHoursText(windowMinutes), label),
        "accent", "surface", w)

    if count < 2 then
        p:text(x0, y0 + math.floor(h / 2), "数据采集中…", "warning", "surface", w)
        return
    end

    local minimum, maximum = values[1], values[1]
    for index = 2, count do
        local value = values[index]
        if value < minimum then minimum = value end
        if value > maximum then maximum = value end
    end
    if minimum == maximum then maximum = minimum + 1 end

    grid(self, context, x0, y0, w, h)
    local color = context.theme.series[level]
    p:setForeground(color)
    p:setBackground("surface")
    local previous
    for index = 1, count do
        local x = x0 + math.floor((index - 1) / (count - 1) * (w - 1))
        local y = y0 + h - 1 - math.floor((values[index] - minimum) / (maximum - minimum) * (h - 1))
        if previous then
            local steps = math.max(1, math.abs(x - previous.x))
            for step = 0, steps do
                local px = previous.x + math.floor((x - previous.x) * step / steps)
                local py = previous.y + math.floor((y - previous.y) * step / steps)
                p.gpu.set(px, py, "█")
            end
        else
            p.gpu.set(x, y, "█")
        end
        previous = { x = x, y = y }
    end

    gutter(self, context, r, y0, maximum, "warning")
    gutter(self, context, r, y0 + h - 1, minimum, "warning")
    labels(self, context, x0, y0, w, h, count, history.interval or 30)
end

local function niceCeil(value)
    if value <= 0 then return 1 end
    local power = 1
    while power * 10 <= value do power = power * 10 end
    local fraction = value / power
    local step = fraction <= 1 and 1 or fraction <= 2 and 2 or fraction <= 5 and 5 or 10
    return step * power
end

local function drawBars(self, context, r, history)
    local p = context.painter
    local x0, y0, w, h = metrics(r)
    if w < 8 or h < 4 then return end
    local values, data = {}, {}
    for level = 1, constants.LEVEL_COUNT do
        local series = (history.values or {})[level] or {}
        values[level] = #series >= 2 and (series[#series] - series[1]) or 0
        data[level] = #series
    end
    if history.count < 2 then
        p:text(x0, y0 + math.floor(h / 2), "数据采集中…", "warning", "surface", w)
        return
    end

    grid(self, context, x0, y0, w, h)
    local extreme = 0
    for index = 1, #values do
        if math.abs(values[index]) > extreme then extreme = math.abs(values[index]) end
    end
    local bound = niceCeil(extreme * 1.05)
    local minValue, maxValue = -bound, bound
    local span = maxValue - minValue
    local function yOf(value)
        return y0 + h - 2 - math.floor((value - minValue) / span * (h - 2))
    end
    local zeroY = yOf(0)
    p:setForeground("muted")
    p:setBackground("surface")
    p.gpu.fill(x0, zeroY, w, 1, "─")

    local cellW = math.max(3, math.floor(w / constants.LEVEL_COUNT))
    local barW = math.max(1, math.min(cellW - 2, w))
    for level = 1, constants.LEVEL_COUNT do
        local value = values[level]
        local barX = x0 + (level - 1) * cellW + math.floor((cellW - barW) / 2)
        barX = math.max(x0, math.min(barX, x0 + w - barW))
        local valueY = yOf(value)
        local top = math.max(y0, math.min(zeroY, valueY))
        local bottom = math.min(y0 + h - 1, math.max(zeroY, valueY))
        if value ~= 0 then
            local color = value >= 0 and context.theme.color.accent or context.theme.color.danger
            p:fill({ x = barX, y = top, w = barW, h = math.max(1, bottom - top + 1) }, color)
        end
        local text = "T" .. level
        local labelX = x0 + (level - 1) * cellW
            + math.floor((cellW - p:measure(text)) / 2)
        p:text(labelX, y0 + h, text, "muted", "surface", cellW)
        if cellW >= 7 and data[level] >= 2 then
            local valueText = shortNumber(value, cellW)
            local textX = x0 + (level - 1) * cellW
                + math.floor((cellW - p:measure(valueText)) / 2)
            textX = math.max(x0, math.min(textX, x0 + w - p:measure(valueText)))
            local textY = value >= 0 and (top - 1) or (bottom + 1)
            textY = math.max(y0, math.min(y0 + h - 2, textY))
            p:text(textX, textY, valueText, value >= 0 and "accent" or "danger", "surface", cellW)
        end
    end
    gutter(self, context, r, y0, bound, "warning")
    gutter(self, context, r, zeroY, 0, "muted")
    gutter(self, context, r, y0 + h - 2, -bound, "warning")
end

function Chart:render(context)
    local p = context.painter
    local r = self.rect
    p:panel(r)
    if r.h < 7 or r.w < 24 then return end
    local history = self.props.history or { count = 0, values = {} }
    local windowMinutes = tonumber(history.windowMinutes) or 40
    chips(self, context, r, windowMinutes)

    local body = { x = r.x + 1, y = r.y + 2, w = math.max(1, r.w - 2), h = math.max(1, r.h - 3) }
    p:fill(body, "surface")

    if (history.count or 0) == 0 then
        local tip = "数据采集中…"
        p:text(r.x + math.max(1, math.floor((r.w - p:measure(tip)) / 2)),
            r.y + math.floor(r.h / 2), tip, "warning", "surface", r.w - 6)
        return
    end

    local level = context.ui.chartLevel or 0
    if level == 0 then
        drawBars(self, context, r, history)
    else
        drawSeries(self, context, r, history, level)
    end
end

return Chart
