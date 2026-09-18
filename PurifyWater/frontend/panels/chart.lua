--------------------------------------------------------------------------------
-- frontend/panels/chart.lua
--------------------------------------------------------------------------------
-- 【职责】水量监视：标题行是一排可点的等级按钮（`全部 | T1 | … | T8`），下面是图
-- 【依赖】frontend/{state,theme,widgets,charts}、shared/constants、unicode
-- 【被谁用】frontend/render
--
-- 【两种看法】全部 = 近 1 游戏日各级水量**变化量**柱状图（涨=蓝 / 跌=红）；
--   Tn = 近 2 游戏日该级水量采样曲线（y 轴自适应）。
-- 时间窗口由 viewmodel 按 CONFIG.CHART 算好（1 游戏日 = 86400 os 秒）。
--------------------------------------------------------------------------------

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

    -- 标题行：等级按钮（全部 + T1..T8），登记热区给 input
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

    -- 右上角：这一屏看的是多长的窗口
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
        -- 全部：各级水量变化量柱状图（量基相同：都是 mB）
        local values, labels = {}, {}
        for level = 1, constants.LEVEL_COUNT do
            local series        = history.values[level] or {}
            values[#values + 1] = (#series >= 2) and (series[#series] - series[1]) or 0
            labels[#labels + 1] = "T" .. level
        end
        charts.bars(area, values, labels,
            string.format("近 %d 游戏日 各级水量变化（柱向上=增加，向下=减少）", days))
    else
        -- 单级：近 2 游戏日的采样曲线（自适应范围）
        local level = fstate.chartLevel
        local row   = data.levels[level]
        charts.series(area,
            { { values = history.values[level] or {}, color = theme.seriesColor(level) } },
            history.times,
            -- 标题不再重复级号：row.label 本身带 "T3"，再加 T%d 会变成 "T3 T3絮凝"
            string.format("近 %d 游戏日 %s 水量曲线", days,
                row and row.label or ("T" .. level)))
    end
end

--- 指纹：选中项 + 点数 + 窗口 + 面板高（+ priority：它决定边框色）
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
