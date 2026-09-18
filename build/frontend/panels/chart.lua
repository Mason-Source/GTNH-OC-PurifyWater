local unicode   = require("unicode")
local constants = require("shared.constants")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local charts    = require("frontend.charts")
local chart     = {}
function chart.draw(data)
    local area = fstate.areas.chart
    widgets.clearArea(area.x, area.y, area.w, area.h)
    widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(data.system.priority == "high"))
    fstate.chartChips = {}
    local x = area.x + 2
    local function chip(level, text)
        local width  = unicode.wlen(text) + 2
        local active = (fstate.chartLevel == level)
        widgets.drawText(x, area.y + 1, " " .. text .. " ",
            active and theme.COLORS.BG or (level == 0 and theme.COLORS.TEXT_CYAN or theme.seriesColor(level)),
            active and theme.COLORS.TEXT_CYAN or theme.COLORS.BTN_BG)
        fstate.chartChips[level] = { x = x, y = area.y + 1, w = width, h = 1 }
        x = x + width + 1
    end
    chip(0, "全部")
    for level = 1, constants.LEVEL_COUNT do
        chip(level, "T" .. level)
    end
    local days = data.historyDays or 0
    if days > 0 then
        widgets.drawTextRight(area.x, area.w - 3, area.y + 1,
            string.format("近 %d 游戏日 ", days), theme.COLORS.TEXT_DISABLED)
    end
    local history = data.history
    if not history or #(history.times or {}) < 2 then
        widgets.drawCenteredTip({ x = area.x, y = area.y + 2, w = area.w, h = area.h - 3 },
            "数据采集中…（每 30 秒一个点）")
        return
    end
    if fstate.chartLevel == 0 then
        local values, labels = {}, {}
        for level = 1, constants.LEVEL_COUNT do
            local series        = history.values[level] or {}
            values[#values + 1] = (#series >= 2) and (series[#series] - series[1]) or 0
            labels[#labels + 1] = "T" .. level
        end
        charts.bars(area, values, labels,
            string.format("近 %d 游戏日 各级水量变化（柱向上=增加，向下=减少）", days))
    else
        local level = fstate.chartLevel
        local row   = data.levels[level]
        charts.series(area,
            { { values = history.values[level] or {}, color = theme.seriesColor(level) } },
            history.times,
            string.format("近 %d 游戏日 %s 水量曲线", days,
                row and row.label or ("T" .. level)))
    end
end
function chart.fingerprint(data)
    local history = data.history or { times = {}, values = {} }
    local parts   = {
        tostring(data.system.priority),
        tostring(fstate.chartLevel),
        tostring(#(history.times or {})),
        tostring(data.historyDays or 0),
        tostring(fstate.areas.chart and fstate.areas.chart.h or 0)
    }
    for level = 1, constants.LEVEL_COUNT do
        local series      = history.values[level] or {}
        parts[#parts + 1] = tostring(series[1] or 0) .. "," .. tostring(series[#series] or 0)
    end
    return table.concat(parts, "\x1f")
end
return chart
