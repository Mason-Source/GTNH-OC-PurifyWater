local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local keypad  = {}
local KEY_W   = 8
local KEY_GAP = 2
local SEP     = 3
local DIGITS  = {
    { { "7", "digit", "7" }, { "8", "digit", "8" }, { "9", "digit", "9" } },
    { { "4", "digit", "4" }, { "5", "digit", "5" }, { "6", "digit", "6" } },
    { { "1", "digit", "1" }, { "2", "digit", "2" }, { "3", "digit", "3" } },
    { nil,                   { "0", "digit", "0" }, nil }
}
local ACTS    = {
    { { "x2", "mul", "2" }, { "x10", "mul", "10" }, { "x100", "mul", "100" } },
    { { "/2", "div", "2" }, { "/10", "div", "10" }, { "/100", "div", "100" } },
    { { "x1000", "mul", "1000" }, { "/1000", "div", "1000" }, { "←", "back", "" } },
    { { "C", "clear", "" }, { "✔", "commit", "" }, { "✘", "cancel", "" } }
}
local PRESETS = {
    { { "1k", "set", "1000" }, { "10k", "set", "10000" }, { "100k", "set", "100000" } },
    { { "1M", "set", "1000000" }, { "10M", "set", "10000000" }, { "100M", "set", "100000000" } },
    { { "1G", "set", "1000000000" }, { "10G", "set", "10000000000" }, { "100G", "set", "100000000000" } },
    { { "1T", "set", "1000000000000" }, { "10T", "set", "10000000000000" }, { "=上级", "copy", "" } }
}
local function keyEnabled(kind)
    if not fstate.configSel then return false end
    if kind == "copy" and fstate.configSel <= 1 then return false end
    return true
end
local function keyColor(kind)
    if kind == "commit" then return theme.COLORS.TEXT_GREEN end
    if kind == "cancel" then return theme.COLORS.TEXT_DISABLED end
    if kind == "copy" then return theme.COLORS.TEXT_YELLOW end
    if kind == "mul" or kind == "div" then return theme.COLORS.TEXT_YELLOW end
    if kind == "set" then return theme.COLORS.TEXT_CYAN end
    return theme.COLORS.TEXT
end
local function padWidth(rows)
    local cols = 0
    for _, row in ipairs(rows) do cols = math.max(cols, #row) end
    return cols * (KEY_W + KEY_GAP) - KEY_GAP
end
local function drawPad(x, y, rows)
    local cols = 0
    for _, row in ipairs(rows) do cols = math.max(cols, #row) end
    for r = 1, #rows do
        for c = 1, cols do
            local key = rows[r][c]
            if key then
                local keyX     = x + (c - 1) * (KEY_W + KEY_GAP)
                local keyY     = y + (r - 1)
                local disabled = not keyEnabled(key[2])
                widgets.drawButton(keyX, keyY, KEY_W, key[1], keyColor(key[2]), nil, disabled)
                if not disabled then
                    fstate.keyCells[#fstate.keyCells + 1] = {
                        x = keyX, y = keyY, w = KEY_W, h = 1, kind = key[2], value = key[3]
                    }
                end
            end
        end
    end
end
function keypad.draw(data)
    local area = fstate.areas.keypad
    widgets.clearArea(area.x, area.y, area.w, area.h)
    fstate.keyCells  = {}
    local wA, wB, wC = padWidth(DIGITS), padWidth(ACTS), padWidth(PRESETS)
    local inner      = area.w - 4
    local total      = wA + wB + wC + SEP * 2
    local kx         = area.x + 2 + math.max(0, math.floor((inner - total) / 2))
    local ky         = area.y + 1
    local xB         = kx + wA
    local xC         = xB + SEP + wB
    drawPad(kx, ky, DIGITS)
    for r = 0, 3 do
        widgets.drawText(xB + math.floor(SEP / 2), ky + r, "│", theme.COLORS.CHART_AXIS)
    end
    drawPad(xB + SEP, ky, ACTS)
    for r = 0, 3 do
        widgets.drawText(xC + math.floor(SEP / 2), ky + r, "│", theme.COLORS.CHART_AXIS)
    end
    drawPad(xC + SEP, ky, PRESETS)
end
function keypad.fingerprint(data)
    local area = fstate.areas.keypad
    return table.concat({
        tostring(area and area.w or 0), tostring(area and area.h or 0),
        tostring(fstate.configSel or 0)
    }, "\x1f")
end
return keypad
