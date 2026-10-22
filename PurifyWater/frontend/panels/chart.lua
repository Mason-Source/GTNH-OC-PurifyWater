--------------------------------------------------------------------------------
-- frontend/panels/chart.lua
--------------------------------------------------------------------------------
-- 【职责】水量监视：标题行是一排等级按钮，下面是图
-- 【依赖】frontend/{state,theme,widgets,charts}、shared/constants、unicode
-- 【被谁用】frontend/render
--
-- 全部 = 近 1 游戏日变化量柱状图；Tn = 近 2 游戏日采样曲线。窗口由 viewmodel 算。
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
    widgets.drawPanelFrame(area, nil, nil, theme.borderColor(data.system.priority == "high"))

    -- 标题行：等级按钮（全部 + T1..T8）；切档位只是本地视图动作，主端/镜像端都登记、都画一套色
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

    -- 右上角：窗口时长
    local days = data.historyDays or 0
    if days > 0 then
        widgets.drawTextRight(area.x, area.w - 3, area.y + 1,
            string.format("近 %d 游戏日 ", days), theme.COLORS.TEXT_DISABLED)
    end

    local history = data.history
    if not history or #(history.times or {}) < 2 then
        widgets.drawCenteredTip({ x = area.x, y = area.y + 2, w = area.w, h = area.h - 3 },
            "数据采集中…")
        return
    end

    if fstate.chartLevel == 0 then
        -- 全部：各级变化量柱状图（单位都是 mB）
        local values, labels = {}, {}
        for level = 1, constants.LEVEL_COUNT do
            local series        = history.values[level] or {}
            values[#values + 1] = (#series >= 2) and (series[#series] - series[1]) or 0
            labels[#labels + 1] = "T" .. level
        end
        charts.bars(area, values, labels,
            string.format("近 %d 游戏日 各级水量变化", days))
    else
        -- 单级：近 2 游戏日采样曲线
        local level = fstate.chartLevel
        local row   = data.levels[level]
        charts.series(area,
            { { values = history.values[level] or {}, color = theme.seriesColor(level) } },
            history.times,
            -- row.label 自带级号，不再加 T%d
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
