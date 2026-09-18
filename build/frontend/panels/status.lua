local unicode       = require("unicode")
local constants     = require("shared.constants")
local fstate        = require("frontend.state")
local theme         = require("frontend.theme")
local widgets       = require("frontend.widgets")
local layout        = require("frontend.layout")
local detail        = require("frontend.panels.detail")
local status        = {}
local lastWasDetail = false
local function switchText(row)
    if (row.deployed or 0) == 0 then return "未部署", theme.COLORS.TEXT_RED end
    if row.switch == nil then return "读不到", theme.COLORS.TEXT_RED end
    if row.switch then
        return string.format("开 %s", row.runText), theme.COLORS.TEXT_GREEN
    end
    return string.format("关 %s", row.runText), theme.COLORS.TEXT_YELLOW
end
function status.draw(data)
    if fstate.detailLevel then
        fstate.levelRows = {}
        lastWasDetail    = true
        return detail.draw(data, fstate.areas.status)
    end
    local area       = fstate.areas.status
    local titleY     = area.y + 1
    local hint       = "点某一级看详情 →"
    local label      = "运行周期 "
    local labelX     = area.x + 2 + 12 + 1
    local barX       = labelX + unicode.wlen(label)
    local pctW       = 6
    local pctX       = area.x + 2 + (area.w - 4) - unicode.wlen(hint) - 2 - pctW
    local barW       = pctX - barX - 1
    local frameDirty = lastWasDetail or fstate.subDirty("status", "frame", table.concat({ area.x, area.y,
        area.w, area.h, tostring(data.system.priority) }, ":"))
    lastWasDetail    = false
    if frameDirty then
        widgets.clearArea(area.x, area.y, area.w, area.h)
        widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(data.system.priority == "high"))
        widgets.drawText(area.x + 2, titleY, "各级净水状态", theme.COLORS.TEXT_CYAN)
        if barW >= 8 then
            widgets.drawText(labelX, titleY, label, theme.COLORS.TEXT_DISABLED)
        end
        widgets.drawTextRight(area.x + 2, area.w - 4, titleY, hint, theme.COLORS.TEXT_DISABLED)
    end
    local cycleFp = table.concat({ tostring(data.cycleText),
        tostring(math.floor((data.cycleRatio or 0) * math.max(0, barW))), tostring(barX), tostring(barW) }, ":")
    local cycleDirty = fstate.subDirty("status", "cycle", cycleFp)
    if frameDirty or cycleDirty then
        if barW >= 8 then
            widgets.drawBar(barX, titleY, barW, data.cycleRatio,
                theme.COLORS.CYCLE_FILL, theme.COLORS.CYCLE_BG)
        end
        widgets.clearArea(pctX, titleY, pctW, 1)
        widgets.drawTextRight(pctX, pctW, titleY, tostring(data.cycleText), theme.COLORS.TEXT_CYAN)
    end
    local top    = area.y + 2
    local bottom = area.y + area.h - 2
    local avail  = bottom - top + 1
    local rowH   = (avail >= constants.LEVEL_COUNT * 2) and 2 or 1
    local inner  = { x = area.x + 2, w = area.w - 4 }
    local cols   = layout.cols(inner, { 0.30, 0.24, 0.46 })
    local barCol = layout.cols(inner, { 0.62, 0.38 })
    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        local y   = top + (level - 1) * rowH
        if y > bottom then break end
        fstate.levelRows[level]      = { x = area.x, y = y, w = area.w, h = rowH }
        local name                   = string.format("%s %s", row.label, row.deployText)
        local switchTxt, switchColor = switchText(row)
        local mark                   = row.rule.enabled and "[√]" or "[  ]"
        local rateW                  = math.max(4, unicode.wlen(row.rateText))
        local waterW                 = math.max(8, cols[3].w - rateW - 1)
        local waterText              = string.format("水量 %s", row.waterOfText)
        if unicode.wlen(waterText) > waterW then
            waterText = string.format("%s/%s", row.waterText, row.thresholdText)
        end
        if unicode.wlen(waterText) > waterW then
            waterText = unicode.sub(waterText, 1, math.max(1, waterW - 1)) .. "…"
        end
        local barW2, pText
        if rowH == 2 then
            barW2 = math.max(4, barCol[1].w - 2)
            local stale = row.sampleStale and row.sample ~= nil and "(上次)" or ""
            pText = ((row.deployed or 0) == 0) and "并行 -"
                or string.format("并行 %s%s / 建议 %s", row.sampleText, stale, row.suggestText)
        end
        local rowFp = table.concat({
            y, rowH, name, switchTxt, mark,
            tostring(row.running), tostring(row.rule.enabled),
            waterText, row.rateText,
            tostring(barW2 or ""), tostring((rowH == 2) and math.floor((row.ratio or 0) * barW2) or ""),
            pText or ""
        }, ":")
        local rowDirty = fstate.subDirty("status", "row" .. level, rowFp)
        if frameDirty or rowDirty then
            widgets.clearArea(inner.x, y, inner.w, rowH)
            widgets.drawText(cols[1].x, y, name,
                row.running and theme.COLORS.TEXT or theme.COLORS.TEXT_DISABLED)
            widgets.drawText(cols[2].x, y, mark,
                row.rule.enabled and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED)
            widgets.drawText(cols[2].x + 5, y, switchTxt, switchColor)
            widgets.drawText(cols[3].x, y, waterText, theme.COLORS.TEXT)
            widgets.drawTextRight(cols[3].x, cols[3].w, y, row.rateText, theme.COLORS.TEXT_CYAN)
            if rowH == 2 then
                widgets.drawBar(barCol[1].x, y + 1, barW2, row.ratio)
                widgets.drawTextRight(barCol[2].x, barCol[2].w, y + 1, pText, theme.COLORS.TEXT_CYAN)
            end
        end
    end
end
function status.fingerprint(data)
    if fstate.detailLevel then
        return "detail\x1f" .. detail.fingerprint(data)
    end
    local parts = { tostring(data.system.priority),
        tostring(data.cycleText), tostring(math.floor((data.cycleRatio or 0) * 100)),
        tostring(fstate.areas.status and fstate.areas.status.h or 0),
        tostring(fstate.areas.status and fstate.areas.status.w or 0) }
    for level = 1, constants.LEVEL_COUNT do
        local row         = data.levels[level]
        parts[#parts + 1] = table.concat({
            row.deployed, row.switchText, row.runText, row.waterText, row.thresholdText,
            row.sampleText, tostring(row.sampleStale), row.suggestText, row.rateText,
            tostring(math.floor((row.ratio or 0) * 100)),
            tostring(row.rule.enabled), tostring(row.running)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end
return status
