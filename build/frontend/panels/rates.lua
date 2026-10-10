local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")
local rates     = {}
local KEY_W     = 8
local KEY_GAP   = 2
local GRID      = {
    { { "7", "digit", "7" }, { "8", "digit", "8" }, { "9", "digit", "9" }, { "←", "back", "" } },
    { { "4", "digit", "4" }, { "5", "digit", "5" }, { "6", "digit", "6" }, { "C", "clear", "" } },
    { { "1", "digit", "1" }, { "2", "digit", "2" }, { "3", "digit", "3" }, { "✔", "commit", "" } },
    { { "0", "digit", "0" }, nil, nil, { "✘", "cancel", "" } }
}
function rates.draw(data)
    local area = fstate.areas.rates
    fstate.rateRows, fstate.rateKeys = {}, {}
    fstate.rateBoostRow = nil
    if not area or area.h < 4 then return end
    widgets.clearArea(area.x, area.y, area.w, area.h)
    widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(false))
    local sys      = (data and data.system) or {}
    widgets.drawText(area.x + 2, area.y + 1,
        string.format("速率权重（点某级选中，用右侧键盘改；0-%d 整数）", CONFIG.RATES.MAX_WEIGHT),
        theme.COLORS.TEXT_CYAN)
    local inner  = { x = area.x + 2, w = math.max(0, area.w - 4) }
    local halves = layout.cols(inner, { 0.62, 0.38 })
    local left, right = halves[1], halves[2]
    local cols   = layout.cols(left, { 0.16, 0.26, 0.58 })
    local headY  = area.y + 2
    local lastY  = area.y + area.h - 3
    widgets.drawText(cols[1].x, headY, "级", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(cols[2].x, headY, "权重", theme.COLORS.TEXT_DISABLED)
    widgets.drawTextRight(cols[3].x, cols[3].w, headY, "建议并行", theme.COLORS.TEXT_DISABLED)
    for level = 1, constants.LEVEL_COUNT do
        local row = (data and data.levels and data.levels[level]) or {}
        local y   = headY + level
        if y > lastY then break end
        local sel = (fstate.rateSel == level)
        local bg  = sel and theme.COLORS.BTN_BG_HOVER or nil
        if sel then widgets.clearArea(left.x, y, left.w, 1, theme.COLORS.BTN_BG_HOVER) end
        widgets.drawText(cols[1].x, y, tostring(row.label or ("T" .. level)), theme.COLORS.TEXT_CYAN, bg)
        local weightText = sel and ((fstate.rateBuf or "") .. "_") or tostring(row.weight or 0)
        widgets.drawText(cols[2].x, y, weightText,
            sel and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT, bg)
        widgets.drawTextRight(cols[3].x, cols[3].w, y, tostring(row.suggestText or "-"),
            sel and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT_DISABLED, bg)
        fstate.rateRows[level] = { x = left.x, y = y, w = left.w, h = 1 }
    end
    local keypadW = 4 * KEY_W + 3 * KEY_GAP
    local keypadX = right.x + math.max(0, math.floor((right.w - keypadW) / 2))
    local keypadY = area.y + 2
    local enabled = (fstate.rateSel ~= nil) and (right.w >= keypadW)
    for r, rowDef in ipairs(GRID) do
        for c, key in ipairs(rowDef) do
            if key then
                local x = keypadX + (c - 1) * (KEY_W + KEY_GAP)
                local y = keypadY + (r - 1)
                widgets.drawButton(x, y, KEY_W, key[1], theme.keyColor(key[2]), nil, not enabled)
                if enabled then
                    fstate.rateKeys[#fstate.rateKeys + 1] = {
                        x = x, y = y, w = KEY_W, h = 1, kind = key[2], value = key[3]
                    }
                end
            end
        end
    end
    local boostY = area.y + area.h - 2
    fstate.rateBoostRow = { x = area.x + 2, y = boostY, w = area.w - 4, h = 1 }
    widgets.drawText(area.x + 2, boostY,
        string.format("T7 增产倍率：×%s（点这一行切换 1 / 1.25 / 1.5 / 1.75 / 2）",
            tostring(sys.t7Boost or 1)), theme.COLORS.TEXT)
end
function rates.fingerprint(data)
    local area  = fstate.areas.rates
    local sys   = (data and data.system) or {}
    local parts = {
        tostring(area and area.x or 0), tostring(area and area.y or 0),
        tostring(area and area.w or 0), tostring(area and area.h or 0),
        tostring(sys.mode), tostring(sys.enforceThreshold), tostring(sys.t7Boost),
        tostring(fstate.rateSel or 0), tostring(fstate.rateBuf or "")
    }
    for level = 1, constants.LEVEL_COUNT do
        local row = (data and data.levels and data.levels[level]) or {}
        parts[#parts + 1] = table.concat({
            tostring(row.label), tostring(row.weight), tostring(row.suggest)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end
return rates
