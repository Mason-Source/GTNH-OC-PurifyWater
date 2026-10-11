local constants = require("shared.constants")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")
local config    = {}
local COLS      = {
    { head = "级" },
    { key = "enabled", head = "勾选" },
    { key = "threshold", head = "阈值(kL)", align = "right" },
    { key = "weight", head = "权重", align = "right" },
    { key = "boost", head = "增产", align = "right" }
}
local COL_W     = { 0.12, 0.12, 0.38, 0.20, 0.18 }
local function effectText(sys)
    local eff  = (sys and sys.effect) or {}
    local on, off = {}, {}
    for _, item in ipairs({
        { "enabled", "勾选" }, { "threshold", "阈值" },
        { "weight", "权重" }, { "boost", "增产" }
    }) do
        if eff[item[1]] then on[#on + 1] = item[2] else off[#off + 1] = item[2] end
    end
    local head = (sys and sys.mode == "rate")
        and ("速率调度" .. (sys.enforceThreshold and "（受阈值约束）" or "（不受阈值约束）"))
        or "阈值调度"
    local text = head .. "："
        .. ((#on > 0) and (table.concat(on, "/") .. " 生效") or "没有列生效")
    if #off > 0 then text = text .. "，" .. table.concat(off, "/") .. " 待用" end
    return text
end
local function numberText(value)
    value = tonumber(value) or 0
    if value == math.floor(value) then return string.format("%d", value) end
    return string.format("%g", value)
end
function config.draw(data)
    local area = fstate.areas.config
    if not area or area.h < 3 then return end
    local sys   = data.system or {}
    local eff   = sys.effect or {}
    local inner = { x = area.x + 2, w = area.w - 4 }
    local cols  = layout.cols(inner, COL_W)
    widgets.drawBorder(area.x, area.y, area.w, area.h,
        theme.borderColor(sys.priority == "high"))
    widgets.clearArea(area.x + 1, area.y + 1, area.w - 2, 2)
    widgets.drawText(area.x + 2, area.y + 1, "调度配置", theme.COLORS.TEXT_CYAN)
    widgets.drawText(area.x + 12, area.y + 1, effectText(sys), theme.COLORS.TEXT_DISABLED)
    for index, col in ipairs(COLS) do
        if col.align == "right" then
            widgets.drawTextRight(cols[index].x, cols[index].w, area.y + 2, col.head,
                theme.COLORS.TEXT_DISABLED)
        else
            widgets.drawText(cols[index].x, area.y + 2, col.head, theme.COLORS.TEXT_DISABLED)
        end
    end
    local selCol = nil
    for index, col in ipairs(COLS) do
        if col.key and col.key == fstate.editField then selCol = index end
    end
    fstate.cells = {}
    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        local y   = area.y + 3 + (level - 1)
        if y > area.y + area.h - 2 then break end
        local sel  = (fstate.editLevel == level)
        local fp   = table.concat({
            row.label, tostring(row.rule.enabled), tostring(row.rule.threshold),
            tostring(row.weight), tostring(row.thresholdOverridden),
            tostring(sys.t7Boost), tostring(sys.mode), tostring(sys.enforceThreshold),
            tostring(sel), tostring(sel and fstate.editField or ""),
            tostring(sel and fstate.editBuf or "")
        }, ":")
        if fstate.subDirty("config", "row" .. level, fp) then
            widgets.clearArea(inner.x, y, inner.w, 1)
            local rowBg = sel and theme.COLORS.BTN_BG_HOVER or nil
            local function cellBg(index)
                return (sel and selCol == index) and theme.COLORS.BTN_BG_HOVER or nil
            end
            if sel and selCol then
                widgets.clearArea(cols[selCol].x, y, cols[selCol].w, 1, theme.COLORS.BTN_BG_HOVER)
            end
            widgets.drawText(cols[1].x, y, row.label, theme.COLORS.TEXT_CYAN, rowBg)
            local mark      = row.rule.enabled and "[√]" or "[ ]"
            local markColor = (row.rule.enabled and eff.enabled)
                and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED
            widgets.drawText(cols[2].x, y, mark, markColor, cellBg(2))
            local thrText  = row.thresholdKText or "-"
            local thrColor = eff.threshold
                and (row.thresholdOverridden and theme.COLORS.TEXT_RED or theme.COLORS.TEXT)
                or theme.COLORS.TEXT_DISABLED
            if sel and fstate.editField == "threshold" then
                thrText, thrColor = (fstate.editBuf or "") .. "_", theme.COLORS.TEXT_YELLOW
            end
            widgets.drawTextRight(cols[3].x, cols[3].w, y, thrText, thrColor, cellBg(3))
            local wText  = tostring(row.weight or 0)
            local wColor = eff.weight and theme.COLORS.TEXT or theme.COLORS.TEXT_DISABLED
            if sel and fstate.editField == "weight" then
                wText, wColor = (fstate.editBuf or "") .. "_", theme.COLORS.TEXT_YELLOW
            end
            widgets.drawTextRight(cols[4].x, cols[4].w, y, wText, wColor, cellBg(4))
            local isT7    = (level == constants.T7_LEVEL)
            local bText   = isT7 and numberText(sys.t7Boost) or "-"
            local bColor  = (not isT7) and theme.COLORS.TEXT_DISABLED
                or ((sel and fstate.editField == "boost") and theme.COLORS.TEXT_YELLOW
                    or (eff.boost and theme.COLORS.TEXT or theme.COLORS.TEXT_DISABLED))
            widgets.drawTextRight(cols[5].x, cols[5].w, y, bText, bColor, cellBg(5))
        end
        fstate.cells[level] = {
            enabled   = { x = cols[2].x, y = y, w = cols[2].w, h = 1 },
            threshold = { x = cols[3].x, y = y, w = cols[3].w, h = 1 },
            weight    = { x = cols[4].x, y = y, w = cols[4].w, h = 1 },
            boost     = (level == constants.T7_LEVEL)
                and { x = cols[5].x, y = y, w = cols[5].w, h = 1 } or nil
        }
    end
end
function config.fingerprint(data)
    local area  = fstate.areas.config or {}
    local sys   = (data and data.system) or {}
    local eff   = sys.effect or {}
    local parts = {
        tostring(area.x or 0), tostring(area.y or 0), tostring(area.w or 0), tostring(area.h or 0),
        tostring(sys.priority), tostring(sys.mode), tostring(sys.enforceThreshold),
        tostring(sys.t7Boost), tostring(eff.enabled), tostring(eff.threshold),
        tostring(eff.weight), tostring(eff.boost),
        tostring(fstate.editLevel or 0), tostring(fstate.editField or ""),
        tostring(fstate.editBuf or "")
    }
    for level = 1, constants.LEVEL_COUNT do
        local row         = data.levels[level]
        parts[#parts + 1] = table.concat({
            row.label, tostring(row.rule.enabled), tostring(row.rule.threshold),
            tostring(row.weight), tostring(row.thresholdOverridden)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end
return config
