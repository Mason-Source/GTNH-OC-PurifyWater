local unicode = require("unicode")
local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local utils   = require("shared.utils")
local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local keypad  = {}
local KEY_W   = 8
local KEY_GAP = 3
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
local function sideFailText(reason)
    if type(reason) ~= "string" or reason == "" then return nil end
    local miss = reason:match("^输入侧缺流体：(.+)$")
    if miss then
        miss = miss:gsub("熔融超导粗胚（UV%-UMV 任意）", "粗胚")
        return "缺 " .. miss
    end
    if reason:find("找不到空容器", 1, true) then return "无输出容器" end
    if reason:find("有多个空容器", 1, true) then return "输出不唯一" end
    return reason
end
local function fitText(text, width)
    if unicode.wlen(text) <= width then return text end
    return unicode.sub(text, 1, math.max(1, width - 1)) .. "…"
end
local function drawProduce(area, data)
    local level = fstate.editLevel or 1
    local pd    = (data and data.produce) or {}
    local info  = (pd.levels or {})[level] or { count = 0, online = 0, machines = {} }
    local list  = info.machines or {}
    local row   = ((data or {}).levels or {})[level]
    local NUM_W, COORD_W, TARGET_W, SIDE_W, ACT_W, GAPW = 4, 20, 14, 18, 8, 2
    local blockW = NUM_W + COORD_W + TARGET_W + SIDE_W + ACT_W + GAPW * 4
    local bx     = area.x + math.max(0, math.floor((area.w - blockW) / 2))
    local xNum    = bx
    local xCoord  = xNum + NUM_W + GAPW
    local xTarget = xCoord + COORD_W + GAPW
    local xSide   = xTarget + TARGET_W + GAPW
    local xAct    = xSide + SIDE_W + GAPW
    local perPage = math.max(1, area.h - 2)
    local pages   = math.max(1, math.ceil(#list / perPage))
    fstate.producePage = math.min(math.max(1, tonumber(fstate.producePage) or 1), pages)
    local y  = area.y
    local cx = area.x
    local function put(text, color, act, value)
        local w = unicode.wlen(text)
        widgets.drawText(cx, y, text, color)
        if act then
            fstate.produceHits[#fstate.produceHits + 1] =
                { x = cx, y = y, w = w, h = 1, act = act, value = value }
        end
        cx = cx + w
    end
    put(string.format("制作自动化 · %s", constants.levelLabel(level)), theme.COLORS.TEXT_CYAN)
    cx = cx + 3
    put(string.format("%d/%d 就绪", info.configured or 0, info.count or 0), theme.COLORS.TEXT)
    if pages > 1 then
        cx = cx + 2
        if fstate.producePage > 1 then put("‹ ", theme.COLORS.TEXT_CYAN, "page", -1) end
        put(string.format("%d/%d", fstate.producePage, pages), theme.COLORS.TEXT_DISABLED)
        if fstate.producePage < pages then put(" ›", theme.COLORS.TEXT_CYAN, "page", 1) end
    end
    cx = cx + 2
    local enabled = row and row.produceEnabled == true
    local toggle  = enabled and "[关]" or "[开]"
    put(toggle, enabled and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT, "toggle")
    if info.state == "blocked" and info.reason then
        cx = cx + 2
        put("强制关断：" .. tostring(info.reason), theme.COLORS.TEXT_YELLOW)
    end
    local binding = pd.binding
    if binding and binding.level == level then
        cx = cx + 2
        put("| 绑定中：放下转运器并接入网络", theme.COLORS.TEXT_YELLOW)
        cx = cx + 2
        put("[取消]", theme.COLORS.TEXT_RED, "cancel")
    end
    local hy = area.y + 1
    widgets.drawText(xNum, hy, "#", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xCoord, hy, "坐标", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xTarget, hy, "转运器", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xSide, hy, "侧位", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xAct, hy, "操作", theme.COLORS.TEXT_DISABLED)
    local first = (fstate.producePage - 1) * perPage + 1
    for index = 1, perPage do
        local ry   = hy + index
        local item = list[first + index - 1]
        if item and ry <= area.y + area.h - 1 then
            widgets.drawText(xNum, ry, tostring(first + index - 1), theme.COLORS.TEXT)
            widgets.drawText(xCoord, ry, unicode.sub(item.text or "-", 1, COORD_W), theme.COLORS.TEXT)
            if item.sideState == "ok" then
                widgets.drawText(xSide, ry, "配置就绪", theme.COLORS.TEXT_GREEN)
            elseif item.sideState == "auto" then
                local fail = sideFailText(item.sideFail)
                if fail then
                    widgets.drawText(xSide, ry, fitText("失败·" .. fail, SIDE_W), theme.COLORS.TEXT_RED)
                else
                    widgets.drawText(xSide, ry, "自动配置中", theme.COLORS.TEXT_YELLOW)
                end
            else
                widgets.drawText(xSide, ry, "-", theme.COLORS.TEXT_DISABLED)
            end
            if item.bound and item.online == true then
                widgets.drawText(xTarget, ry, utils.shortAddress(item.bound), theme.COLORS.TEXT)
                local label = "[解绑]"
                widgets.drawText(xAct, ry, label, theme.COLORS.TEXT)
                fstate.produceHits[#fstate.produceHits + 1] = {
                    x = xAct, y = ry, w = unicode.wlen(label), h = 1, act = "unbind", machine = item.address
                }
            else
                local text = item.bound and utils.shortAddress(item.bound) or "未绑定"
                widgets.drawText(xTarget, ry, text, theme.COLORS.TEXT_DISABLED)
                local label = "[绑定]"
                widgets.drawText(xAct, ry, label, theme.COLORS.TEXT_DISABLED)
                fstate.produceHits[#fstate.produceHits + 1] = {
                    x = xAct, y = ry, w = unicode.wlen(label), h = 1, act = "bind", machine = item.address
                }
            end
        end
    end
end
function keypad.draw(data)
    local area = fstate.areas.keypad
    if not area or area.w <= 0 or area.h <= 0 then return end
    widgets.clearArea(area.x, area.y, area.w, area.h)
    fstate.keys = {}
    fstate.produceHits = {}
    if area.h < 2 then return end
    if fstate.editField == "produce" then
        drawProduce(area, data)
        return
    end
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
    local pd = (data and data.produce) or {}
    local pl = (pd.levels or {})[fstate.editLevel or -1] or {}
    parts[#parts + 1] = table.concat({
        tostring(fstate.producePage or 1),
        tostring(pl.enabled), tostring(pl.ready), tostring(pl.reason),
        tostring(pl.bound), tostring(pl.configured), tostring(pl.online), tostring(pl.count),
        tostring((pd.binding or {}).level), tostring((pd.binding or {}).machine)
    }, ":")
    for _, m in ipairs(pl.machines or {}) do
        parts[#parts + 1] = table.concat(
            { m.address, tostring(m.bound), tostring(m.online), tostring(m.text), tostring(m.sideState), tostring(m.sideFail) }, ",")
    end
    return table.concat(parts, "\x1f")
end
return keypad
