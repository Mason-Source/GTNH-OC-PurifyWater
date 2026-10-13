local unicode = require("unicode")
local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local keypad  = {}
local KEY_W   = 8
local KEY_GAP = 2
local SEP     = 3
local OPT_W   = 10
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
local WEIGHTS = {
    { { "1", "digit", "1" }, { "2", "digit", "2" }, { "3", "digit", "3" }, { "4", "digit", "4" }, { "5", "digit", "5" } },
    { { "6", "digit", "6" }, { "7", "digit", "7" }, { "8", "digit", "8" }, { "9", "digit", "9" }, { "0", "digit", "0" } },
    { { "←", "back", "" }, { "C", "clear", "" }, { "✔", "commit", "" }, { "✘", "cancel", "" } }
}
local function padWidth(rows)
    local cols = 0
    for _, row in ipairs(rows) do cols = math.max(cols, #row) end
    return cols * (KEY_W + KEY_GAP) - KEY_GAP
end
local function keyEnabled(kind)
    if not fstate.editField then return false end
    if kind == "copy" and (fstate.editLevel or 1) <= 1 then return false end
    return true
end
local function drawPad(x, y, rows, shift)
    local cols = 0
    for _, row in ipairs(rows) do cols = math.max(cols, #row) end
    for r = 1, #rows do
        local padX = x + ((shift and shift[r]) or 0)
        for c = 1, cols do
            local key = rows[r][c]
            if key then
                local keyX     = padX + (c - 1) * (KEY_W + KEY_GAP)
                local keyY     = y + (r - 1)
                local disabled = not keyEnabled(key[2])
                widgets.drawButton(keyX, keyY, KEY_W, key[1], theme.keyColor(key[2]), nil, disabled)
                if not disabled then
                    fstate.keys[#fstate.keys + 1] = {
                        x = keyX, y = keyY, w = KEY_W, h = 1, kind = key[2], value = key[3]
                    }
                end
            end
        end
    end
end
local function drawOptions(x, y, w, options)
    local total = #options * OPT_W + (#options - 1) * KEY_GAP
    local kx    = x + math.max(0, math.floor((w - total) / 2))
    for index, option in ipairs(options) do
        local keyX  = kx + (index - 1) * (OPT_W + KEY_GAP)
        local color = option.current and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT
        local bg    = option.current and theme.COLORS.BTN_BG_HOVER or nil
        widgets.drawButton(keyX, y, OPT_W, option.label, color, bg)
        fstate.keys[#fstate.keys + 1] = {
            x = keyX, y = y, w = OPT_W, h = 1, kind = option.kind, value = option.value
        }
    end
end
local function numberText(value)
    value = tonumber(value) or 0
    if value == math.floor(value) then return string.format("%d", value) end
    return string.format("%g", value)
end
local function hintText(data)
    local field = fstate.editField
    local label = "T" .. tostring(fstate.editLevel or "")
    if field == "threshold" then
        return string.format("正在编辑 %s 阈值（kL）：%s_   ✔ 保存 · ✘ 取消", label, fstate.editBuf or ""),
            theme.COLORS.TEXT_YELLOW
    elseif field == "weight" then
        return string.format("正在编辑 %s 权重：%s_   ✔ 保存 · ✘ 取消", label, fstate.editBuf or ""),
            theme.COLORS.TEXT_YELLOW
    elseif field == "boost" then
        return string.format("正在编辑 T7 增产倍率（当前 ×%s）：点击切换档位",
            numberText((data and data.system or {}).t7Boost)), theme.COLORS.TEXT_YELLOW
    elseif field == "factor" then
        return string.format("正在编辑 能源仓利用因子（%d-%d%%）：%s_   ✔ 保存 · ✘ 取消",
            CONFIG.ENERGY.FACTOR_MIN, CONFIG.ENERGY.FACTOR_MAX, fstate.editBuf or ""),
            theme.COLORS.TEXT_YELLOW
    elseif field == "strength" then
        return string.format("正在编辑 无线范围（方块，上限 %d）：%s_   ✔ 保存 · ✘ 取消",
            CONFIG.NET.STRENGTH_MAX, fstate.editBuf or ""),
            theme.COLORS.TEXT_YELLOW
    end
    return "选中后编辑；勾选切换", theme.COLORS.TEXT_DISABLED
end
function keypad.draw(data)
    local area = fstate.areas.keypad
    if not area or area.w <= 0 or area.h <= 0 then return end
    widgets.clearArea(area.x, area.y, area.w, area.h)
    fstate.keys = {}
    if area.h < 2 then return end
    local hint, color = hintText(data)
    if unicode.wlen(hint) > area.w then
        hint = unicode.sub(hint, 1, math.max(1, area.w - 1)) .. "…"
    end
    widgets.drawText(area.x, area.y, hint, color)
    local rows  = area.h - 1
    local function slotY(count)
        return area.y + 1 + math.max(0, math.floor((rows - count) / 2))
    end
    if fstate.editField == "threshold" then
        local wA, wB, wC = padWidth(DIGITS), padWidth(ACTS), padWidth(PRESETS)
        local total      = wA + wB + wC + SEP * 2
        local kx         = area.x + math.max(0, math.floor((area.w - total) / 2))
        local ky         = slotY(4)
        local xB         = kx + wA
        local xC         = xB + SEP + wB
        drawPad(kx, ky, DIGITS)
        for r = 0, 3 do
            widgets.drawText(xB + math.floor(SEP / 2), ky + r, "│", theme.CHART_AXIS)
        end
        drawPad(xB + SEP, ky, ACTS)
        for r = 0, 3 do
            widgets.drawText(xC + math.floor(SEP / 2), ky + r, "│", theme.CHART_AXIS)
        end
        drawPad(xC + SEP, ky, PRESETS)
    elseif fstate.editField == "weight" or fstate.editField == "factor"
        or fstate.editField == "strength" then
        local kx = area.x + math.max(0, math.floor((area.w - padWidth(WEIGHTS)) / 2))
        drawPad(kx, slotY(#WEIGHTS), WEIGHTS, { [3] = math.floor((KEY_W + KEY_GAP) / 2) })
    elseif fstate.editField == "boost" then
        local current = tonumber((data and data.system or {}).t7Boost) or 1
        local options = {}
        for _, value in ipairs(constants.T7_BOOST_OPTIONS) do
            options[#options + 1] = {
                label = "×" .. numberText(value), kind = "set_boost",
                value = tostring(value), current = (value == current)
            }
        end
        drawOptions(area.x, slotY(1), area.w, options)
    end
end
function keypad.fingerprint(data)
    local area  = fstate.areas.keypad or {}
    local sys   = (data and data.system) or {}
    local parts = {
        tostring(area.x or 0), tostring(area.y or 0), tostring(area.w or 0), tostring(area.h or 0),
        tostring(fstate.editField or ""), tostring(fstate.editLevel or 0),
        tostring(fstate.editBuf or ""), tostring(sys.t7Boost)
    }
    local row = (data and fstate.editLevel) and data.levels[fstate.editLevel]
    if row then
        parts[#parts + 1] = table.concat({
            tostring(row.rule.enabled), tostring(row.rule.threshold), tostring(row.weight)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end
return keypad
