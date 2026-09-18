local utils        = require("shared.utils")
local unicode      = require("unicode")
local logs         = require("shared.logs")
local fstate       = require("frontend.state")
local theme        = require("frontend.theme")
local widgets      = require("frontend.widgets")
local charts       = {}
charts.PAD_X       = 2
charts.PAD_Y       = 1
charts.GUTTER      = 7
local boundsWarned = false
function charts.fitNumber(value, w)
    w          = math.max(1, math.floor(w or 1))
    local text = utils.formatShortNumber(value or 0)
    if unicode.wlen(text) <= w then return text end
    local short = (text:gsub("%.%d+", "")) 
    if unicode.wlen(short) <= w then return short end
    return unicode.sub(short, 1, math.max(0, w - 1)) .. "…"
end
local function gutterLabel(area, y, value, color)
    widgets.drawTextRight(area.x + 1, charts.GUTTER, y,
        charts.fitNumber(value, charts.GUTTER), color)
end
function charts.checkBounds(tag, x0, y0, w, h, minY, maxY, maxX)
    if boundsWarned then return end
    if maxX > x0 + w - 1 or maxY > y0 + h - 1 or minY < y0 then
        boundsWarned = true
        logs.warn(string.format(
            "%s 绘制越界：画布 x=%d..%d y=%d..%d，实际用到 x..%d y=%d..%d（面板可能太窄）",
            tag, x0, x0 + w - 1, y0, y0 + h - 1, maxX, minY, maxY))
    end
end
function charts.metrics(area, yOffset)
    local x0 = area.x + charts.PAD_X + 1 + charts.GUTTER
    local y0 = area.y + charts.PAD_Y + 2 + (yOffset or 0)
    local w  = area.w - charts.PAD_X * 2 - 2 - charts.GUTTER
    local h  = area.h - 5
    return x0, y0, w, h
end
function charts.clear(x0, y0, w, h)
    fstate.gpu.setBackground(theme.COLORS.BG)
    fstate.gpu.fill(x0, y0, w, h, " ")
end
function charts.grid(x0, y0, w, h, rows)
    if w < 8 or h < 4 then return end
    rows = rows or 4
    fstate.gpu.setForeground(theme.CHART_GRID)
    for i = 1, rows - 1 do
        local y = y0 + math.floor(h * i / rows)
        for x = 0, w - 1 do fstate.gpu.set(x0 + x, y, "·") end
    end
    fstate.gpu.setForeground(theme.CHART_AXIS)
    for x = 0, w - 1 do fstate.gpu.set(x0 + x, y0 + h - 1, "─") end
    for y = 0, h - 1 do fstate.gpu.set(x0 - 1, y0 + y, "│") end
    fstate.gpu.set(x0 - 1, y0 + h - 1, "└")
end
function charts.project(values, x0, y0, w, h, fixedMin, fixedMax)
    local n = #values
    local minVal, maxVal = fixedMin, fixedMax
    if minVal == nil or maxVal == nil then
        minVal, maxVal = values[1], values[1]
        for i = 2, n do
            local v = values[i]
            if v < minVal then minVal = v end
            if v > maxVal then maxVal = v end
        end
    end
    if minVal == maxVal then maxVal = minVal + 1 end
    local points = {}
    for i = 1, n do
        local px = x0 + math.floor((i - 1) / math.max(1, n - 1) * (w - 1))
        local py = y0 + h - 1 - math.floor((values[i] - minVal) / (maxVal - minVal) * (h - 1))
        points[i] = { x = px, y = py }
    end
    return points, minVal, maxVal
end
function charts.series(area, series, times, title)
    local x0, y0, w, h = charts.metrics(area)
    if w < 8 or h < 4 then return false end
    charts.clear(x0, y0, w, h)
    charts.grid(x0, y0, w, h)
    local minVal, maxVal, drawable = nil, nil, 0
    local valid = {}
    for _, line in ipairs(series) do
        local values = line.values or {}
        if #values >= 2 then
            drawable = drawable + 1
            valid[#valid + 1] = line
            for i = 1, #values do
                local v = values[i]
                if minVal == nil or v < minVal then minVal = v end
                if maxVal == nil or v > maxVal then maxVal = v end
            end
        end
    end
    if drawable == 0 then
        widgets.drawText(x0, y0 - 1, title, theme.COLORS.TEXT_CYAN)
        widgets.drawCenteredTip({ x = x0, y = y0, w = w, h = h }, "数据采集中…（每 30 秒一个点）")
        return false
    end
    local minUsedY, maxUsedY, maxUsedX = y0, y0, x0
    for _, line in ipairs(valid) do
        local points = charts.project(line.values, x0, y0, w, h, minVal, maxVal)
        fstate.gpu.setForeground(line.color or theme.CHART_WATER)
        for i = 1, #points - 1 do
            local p1, p2 = points[i], points[i + 1]
            local steps = math.max(1, math.abs(p2.x - p1.x))
            for s = 0, steps do
                local x = p1.x + math.floor((p2.x - p1.x) * s / steps)
                local y = p1.y + math.floor((p2.y - p1.y) * s / steps)
                fstate.gpu.set(x, y, "█")
                minUsedY = math.min(minUsedY, y)
                maxUsedY = math.max(maxUsedY, y)
                maxUsedX = math.max(maxUsedX, x)
            end
        end
    end
    charts.checkBounds("折线", x0, y0, w, h, minUsedY, maxUsedY, maxUsedX)
    widgets.drawText(x0, y0 - 1, title, theme.COLORS.TEXT_CYAN)
    gutterLabel(area, y0, maxVal, theme.COLORS.TEXT_YELLOW)
    gutterLabel(area, y0 + h - 1, minVal, theme.COLORS.TEXT_YELLOW)
    local now = os.time()
    local n   = #times
    if n >= 2 then
        for _, index in ipairs({ 1, math.floor(n / 2) + 1, n }) do
            local point = charts.pointAt(index, n, x0, w)
            local diff  = now - (times[index] or now)
            local text
            if index == n then
                text = "现在"
            elseif diff < 60 then
                text = "刚刚"
            elseif diff < 3600 then
                text = string.format("-%d 分", math.floor(diff / 60))
            else
                text = string.format("-%d 时", math.floor(diff / 3600))
            end
            local labelX = point - math.floor(unicode.wlen(text) / 2)
            labelX = math.max(x0, math.min(labelX, x0 + w - unicode.wlen(text)))
            widgets.drawText(labelX, y0 + h, text, theme.COLORS.TEXT)
        end
    end
    return true
end
local function niceCeil(v)
    if v <= 0 then return 1 end
    local pow = 1
    while pow * 10 <= v do pow = pow * 10 end
    local frac = v / pow
    local step = (frac <= 1) and 1 or (frac <= 2) and 2 or (frac <= 5) and 5 or 10
    return step * pow
end
function charts.bars(area, values, labels, title)
    local x0, y0, w, h = charts.metrics(area)
    if w < 8 or h < 4 then return false end
    charts.clear(x0, y0, w, h)
    charts.grid(x0, y0, w, h)
    local n = #values
    if n == 0 then return false end
    local extreme = 0
    for i = 1, n do
        local v = values[i] or 0
        if math.abs(v) > extreme then extreme = math.abs(v) end
    end
    local bound = niceCeil(extreme * 1.05)
    local minVal, maxVal = -bound, bound
    local span = maxVal - minVal
    local function yOf(v)
        return y0 + h - 2 - math.floor((v - minVal) / span * (h - 2))
    end
    local zeroY = yOf(0)
    fstate.gpu.setForeground(theme.CHART_AXIS)
    for x = 0, w - 1 do fstate.gpu.set(x0 + x, zeroY, "─") end
    local cellW = math.floor(w / n)
    if cellW < 3 then cellW = 3 end
    local barW                         = math.max(1, math.min(cellW - 2, w))
    local rooms                        = (cellW >= 6)
    local minUsedY, maxUsedY, maxUsedX = y0, y0, x0
    for i = 1, n do
        local v      = values[i] or 0
        local barX   = x0 + (i - 1) * cellW + math.floor((cellW - barW) / 2)
        barX         = math.max(x0, math.min(barX, x0 + w - barW))
        local valueY = yOf(v)
        local top    = math.max(y0, math.min(zeroY, valueY))
        local bottom = math.min(y0 + h - 1, math.max(zeroY, valueY))
        local rowH   = math.max(1, bottom - top + 1)
        local color  = (v >= 0) and theme.CHART_WATER or theme.COLORS.TEXT_RED
        if v ~= 0 then
            fstate.gpu.setBackground(color)
            fstate.gpu.fill(barX, top, barW, rowH, " ")
            fstate.gpu.setBackground(theme.COLORS.BG)
            minUsedY = math.min(minUsedY, top)
            maxUsedY = math.max(maxUsedY, top + rowH - 1)
        end
        maxUsedX     = math.max(maxUsedX, barX + barW - 1)
        local label  = tostring(labels[i] or "")
        local labelX = x0 + (i - 1) * cellW + math.floor((cellW - unicode.wlen(label)) / 2)
        labelX       = math.max(x0, math.min(labelX, x0 + w - unicode.wlen(label)))
        widgets.drawText(labelX, y0 + h, label, theme.COLORS.TEXT)
        maxUsedX = math.max(maxUsedX, labelX + unicode.wlen(label) - 1)
        if rooms then
            local text = charts.fitNumber(v, cellW)
            local ty   = (v >= 0) and (top - 1) or (top + rowH)
            if ty > y0 + h - 2 then ty = top - 1 end
            ty          = math.max(y0, math.min(y0 + h - 2, ty))
            local textX = x0 + (i - 1) * cellW + math.floor((cellW - unicode.wlen(text)) / 2)
            textX       = math.max(x0, math.min(textX, x0 + w - unicode.wlen(text)))
            widgets.drawText(textX, ty, text, color)
            maxUsedX = math.max(maxUsedX, textX + unicode.wlen(text) - 1)
        end
    end
    charts.checkBounds("柱状图", x0, y0, w, h, minUsedY, maxUsedY, maxUsedX)
    gutterLabel(area, y0, bound, theme.COLORS.TEXT_YELLOW)
    gutterLabel(area, zeroY, 0, theme.COLORS.CHART_AXIS)
    gutterLabel(area, y0 + h - 2, -bound, theme.COLORS.TEXT_YELLOW)
    return true
end
function charts.pointAt(index, n, x0, w)
    if n <= 1 then return x0 end
    return x0 + math.floor((index - 1) / (n - 1) * (w - 1))
end
return charts
