local fstate         = require("frontend.state")
local widgets        = require("frontend.widgets")
local logs           = require("shared.logs")
local layout         = {}
layout.TAB_H         = 1
layout.CONTROL_H     = 18
layout.MIN_CONTROL_H = 11
layout.MIN_LOG_H     = 6
layout.STATUS_TWO_H  = 19
layout.STATUS_ONE_H  = 12
layout.CONFIG_LIST_H = 12
layout.EDITLINE_H    = 1
layout.KEYPAD_H      = 5
layout.MIN_CHART_H   = 10
layout.SIDE_PAD      = 1
layout.COL_GAP       = 1
function layout.cols(area, weights)
    local out, total = {}, 0
    for _, weight in ipairs(weights) do total = total + weight end
    if total <= 0 then total = 1 end
    local x, left = area.x, area.w
    for index, weight in ipairs(weights) do
        local w
        if index == #weights then
            w = left
        else
            w = math.floor(area.w * weight / total)
            left = left - w
        end
        out[index] = { x = x, w = w }
        x = x + w
    end
    return out
end
function layout.calculate()
    fstate.W, fstate.H = fstate.gpu.getResolution()
    local W, H         = fstate.W, fstate.H
    local grid         = { rows = {}, cols = {} }
    grid.rows.top      = { y = 1, h = layout.TAB_H }
    grid.rows.body     = { y = layout.TAB_H + 1, h = H - layout.TAB_H }
    local leftW        = math.floor(W * 0.30)
    leftW              = math.max(26, math.min(leftW, 46, W - 40))
    local rightW       = W - leftW - layout.SIDE_PAD * 2 - layout.COL_GAP
    grid.cols.left     = { x = 1 + layout.SIDE_PAD, w = leftW }
    grid.cols.right    = { x = 1 + layout.SIDE_PAD + leftW + layout.COL_GAP, w = rightW }
    fstate.grid        = grid
    local bodyY        = grid.rows.body.y
    local bodyH        = grid.rows.body.h
    local statusH      = (bodyH >= layout.STATUS_TWO_H + layout.MIN_CHART_H + 1)
        and layout.STATUS_TWO_H or layout.STATUS_ONE_H
    local chartH       = bodyH - statusH - 1
    if chartH < layout.MIN_CHART_H then
        chartH  = math.min(layout.MIN_CHART_H, bodyH)
        statusH = math.max(6, bodyH - chartH - 1)
    end
    local controlH = math.min(layout.CONTROL_H, bodyH - layout.MIN_LOG_H - 1)
    controlH       = math.max(math.min(layout.MIN_CONTROL_H, bodyH), controlH)
    local logH     = bodyH - controlH - 1
    if logH < layout.MIN_LOG_H then
        logH     = math.min(layout.MIN_LOG_H, bodyH)
        controlH = math.max(6, bodyH - logH - 1)
    end
    fstate.areas.tabBar   = { x = 1, y = grid.rows.top.y, w = W, h = layout.TAB_H }
    fstate.areas.control  = { x = grid.cols.left.x, y = bodyY, w = grid.cols.left.w, h = controlH }
    fstate.areas.log      = {
        x = grid.cols.left.x,
        y = bodyY + controlH + 1,
        w = grid.cols.left.w,
        h = logH
    }
    fstate.areas.status   = { x = grid.cols.right.x, y = bodyY, w = grid.cols.right.w, h = statusH }
    fstate.areas.chart    = {
        x = grid.cols.right.x,
        y = bodyY + statusH + 1,
        w = grid.cols.right.w,
        h = chartH
    }
    local configX         = 1 + layout.SIDE_PAD
    local configW         = W - layout.SIDE_PAD * 2
    local configH         = math.min(layout.CONFIG_LIST_H, bodyH)
    local editH           = math.min(layout.EDITLINE_H, math.max(0, bodyH - configH))
    local keypadH         = math.min(layout.KEYPAD_H, math.max(0, bodyH - configH - editH))
    fstate.areas.config   = { x = configX, y = bodyY, w = configW, h = configH }
    fstate.areas.editline = { x = configX, y = bodyY + configH, w = configW, h = editH }
    fstate.areas.keypad   = { x = configX, y = bodyY + configH + editH, w = configW, h = keypadH }
    logs.debug(string.format("[调试] 布局 控制 %dx%d@%d,%d 状态 %dx%d@%d,%d 图表 %dx%d@%d,%d 日志 %dx%d@%d,%d",
        fstate.areas.control.w, fstate.areas.control.h, fstate.areas.control.x, fstate.areas.control.y,
        fstate.areas.status.w, fstate.areas.status.h, fstate.areas.status.x, fstate.areas.status.y,
        fstate.areas.chart.w, fstate.areas.chart.h, fstate.areas.chart.x, fstate.areas.chart.y,
        fstate.areas.log.w, fstate.areas.log.h, fstate.areas.log.x, fstate.areas.log.y))
    fstate.clearHitboxes()
    fstate.invalidateAll()
end
return layout
