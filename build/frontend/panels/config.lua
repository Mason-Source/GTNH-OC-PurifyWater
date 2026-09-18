local constants = require("shared.constants")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")
local config    = {}
local COL_W     = { 0.16, 0.10, 0.74 }
function config.draw(data)
    local area = fstate.areas.config
    widgets.clearArea(area.x, area.y, area.w, area.h)
    widgets.drawBorder(area.x, area.y, area.w, area.h,
        theme.borderColor(data.system.priority == "high"))
    widgets.drawText(area.x + 2, area.y + 1, "净水厂配置（点某级选中，用下方键盘改阈值）",
        theme.COLORS.TEXT_CYAN)
    local inner                          = { x = area.x + 2, w = area.w - 4 }
    local cols                           = layout.cols(inner, COL_W)
    fstate.checkCells, fstate.configRows = {}, {}
    widgets.drawText(cols[1].x, area.y + 2, "级", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(cols[2].x, area.y + 2, "勾选", theme.COLORS.TEXT_DISABLED)
    widgets.drawTextRight(cols[3].x, cols[3].w, area.y + 2, "阈值 (kL)", theme.COLORS.TEXT_DISABLED)
    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        local y   = area.y + 3 + (level - 1)
        if y > area.y + area.h - 2 then break end
        local sel   = (fstate.configSel == level)
        local rowBg = sel and theme.COLORS.BTN_BG_HOVER or nil
        if sel then widgets.clearArea(inner.x, y, inner.w, 1, theme.COLORS.BTN_BG_HOVER) end
        widgets.drawText(cols[1].x, y, row.label, theme.COLORS.TEXT_CYAN, rowBg)
        fstate.checkCells[level] = { x = cols[2].x, y = y, w = 4, h = 1 }
        widgets.drawText(cols[2].x, y, row.rule.enabled and "[√]" or "[  ]",
            row.rule.enabled and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED, rowBg)
        widgets.drawTextRight(cols[3].x, cols[3].w, y, row.thresholdKText,
            sel and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT, rowBg)
        fstate.configRows[level] = { x = area.x, y = y, w = area.w, h = 1 }
    end
end
function config.fingerprint(data)
    local area  = fstate.areas.config
    local parts = {
        tostring(data.system.priority),
        tostring(area and area.w or 0), tostring(area and area.h or 0),
        tostring(fstate.configSel or 0)
    }
    for level = 1, constants.LEVEL_COUNT do
        local row         = data.levels[level]
        parts[#parts + 1] = table.concat({
            row.label, tostring(row.rule.enabled), tostring(row.rule.threshold)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end
return config
