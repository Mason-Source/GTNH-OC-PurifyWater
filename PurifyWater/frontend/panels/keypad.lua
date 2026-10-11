--------------------------------------------------------------------------------
-- frontend/panels/keypad.lua
--------------------------------------------------------------------------------
-- 【职责】配置页「调度配置」卡内的**固定键盘槽**：按选中的列换成那一列自己的键盘
--   threshold -> 三段键盘（数字 / 倍数 / 档位 + =上级）
--   weight    -> 数字 + ← / C / ✔ / ✘
--   boost     -> 选项键盘（1 / 1.25 / 1.5 / 1.75 / 2，当前档高亮，点即提交）
--   （勾选不走这里：表格里点一下那个格子就直接切换开关，见 frontend/input.applyCell）
-- 【不做什么】不画表格（panels/config）、不碰后端（提交在 input）、不判断业务
-- 【依赖】unicode、frontend/{state,theme,widgets}
-- 【被谁用】frontend/render
--
-- 【为什么固定槽】键盘换样子但**位置不动**：点哪一格都在同一片按键区操作，鼠标不用追着格子跑。
--   槽内第一行永远是"正在改什么 / 怎么用"的提示；键在剩下的行里垂直居中。
-- 【单位 kL】缓冲是**纯数字串**（不带逗号、不带单位）；单位只在表格表头写一次。
-- 【关键位】数字键 / 倍数键 / 档位直选 / =上级（抄上一级）/ ← 退格 / C 清空 / ✔ 确定 / ✘ 取消。
--------------------------------------------------------------------------------

local unicode = require("unicode")

local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")

local constants = require("shared.constants")

local keypad  = {}

-- 键位几何（数值只在这里）
local KEY_W   = 8  -- 普通键宽
local KEY_GAP = 2  -- 键间距
local SEP     = 3  -- 阈值键盘的段间空隙（含那条竖线）
local OPT_W   = 10 -- 选项键宽（"×1.25" 这类档位都放得下）

-- 阈值键盘：三段键盘，行 × 列，每键 = { 显示文本, 语义 kind, 参数 value }
-- 【kind 的语义在 input.applyKey】这里只管"长什么样、点在哪儿"
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

-- 权重键盘：3 行 × 5 列（数字 0-9 + ← / C / ✔ / ✘；最后一行 4 个键居中）
local WEIGHTS = {
    { { "1", "digit", "1" }, { "2", "digit", "2" }, { "3", "digit", "3" }, { "4", "digit", "4" }, { "5", "digit", "5" } },
    { { "6", "digit", "6" }, { "7", "digit", "7" }, { "8", "digit", "8" }, { "9", "digit", "9" }, { "0", "digit", "0" } },
    { { "←", "back", "" }, { "C", "clear", "" }, { "✔", "commit", "" }, { "✘", "cancel", "" } }
}
--- 一张键盘表要占多宽（不画，先量）
-- @param rows table 行 × 列
-- @return number
local function padWidth(rows)
    local cols = 0
    for _, row in ipairs(rows) do cols = math.max(cols, #row) end
    return cols * (KEY_W + KEY_GAP) - KEY_GAP
end

--- 这个键现在能不能按：都要先选中对应列；"抄上级"还要真的有上一级
-- @param field string 正在改的列
-- @param kind string 键的语义
-- @return boolean
local function keyEnabled(kind)
    if not fstate.editField then return false end
    if kind == "copy" and (fstate.editLevel or 1) <= 1 then return false end
    return true
end

--- 画一张键盘表并登记热区
-- 【列数按满格算，不按每行自己的长度】表里允许有 nil 空位（数字键盘的 "0" 就靠空位居中），
--   带洞的行 `#row` 是不确定的（Lua 只保证返回某个边界）—— 所以一律扫到 cols。
-- @param x, y number 左上角
-- @param rows table 行 × 列（行里可以有 nil 空位）
-- @param shift table|nil 可选：`shift[r]` = 这一行额外右移的列数（列数不足的行想居中时用）
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
                    -- 热区里直接带语义：input 不必认识键盘长什么样
                    fstate.keys[#fstate.keys + 1] = {
                        x = keyX, y = keyY, w = KEY_W, h = 1, kind = key[2], value = key[3]
                    }
                end
            end
        end
    end
end

--- 选项键盘（点即提交，没有"确定"键）：当前档高亮成绿
-- @param x, y, w number 槽内可用区（w 用来整排居中）
-- @param options table { { label = , kind = , value = , current = boolean }, ... }
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
--- 档位文本：整数不带小数点（1 / 1.25 / 1.5 / 1.75 / 2）
-- @param value number
-- @return string
local function numberText(value)
    value = tonumber(value) or 0
    if value == math.floor(value) then return string.format("%d", value) end
    return string.format("%g", value)
end

--- 槽内第一行的提示：正在改什么 / 没选中时怎么用
-- @param data table viewmodel 数据（取等级名与当前档位）
-- @return string
-- @return number 颜色
local function hintText(data)
    local field = fstate.editField
    local label = "T" .. tostring(fstate.editLevel or "")
    if field == "threshold" then
        return string.format("正在改 %s 阈值（kL）：%s_   ✔ 保存，✘ 取消", label, fstate.editBuf or ""),
            theme.COLORS.TEXT_YELLOW
    elseif field == "weight" then
        return string.format("正在改 %s 权重：%s_   ✔ 保存，✘ 取消", label, fstate.editBuf or ""),
            theme.COLORS.TEXT_YELLOW
    elseif field == "boost" then
        return string.format("正在改 T7 增产倍率（当前 ×%s）：点下面任意一档即生效",
            numberText((data and data.system or {}).t7Boost)), theme.COLORS.TEXT_YELLOW
    end
    return "点表格里任意一格选中，再用这里的键盘改（勾选格点一下就是切换）", theme.COLORS.TEXT_DISABLED
end

--- 画键盘槽：提示行 + 当前列自己的键盘（键在剩下的行里垂直居中）
-- @param data table viewmodel.build() 的返回
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

    local rows  = area.h - 1 -- 除掉提示行，剩下的给键
    local function slotY(count)
        return area.y + 1 + math.max(0, math.floor((rows - count) / 2))
    end

    if fstate.editField == "threshold" then
        -- 三段排开（数字 / 倍数 / 档位），段间一条竖线
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
    elseif fstate.editField == "weight" then
        local kx = area.x + math.max(0, math.floor((area.w - padWidth(WEIGHTS)) / 2))
        -- 最后一行只有 4 个键：整排右移半格，看起来才是居中的
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

--- 指纹：槽尺寸 + 选中（列 / 级 / 缓冲）+ 选中那一行现在的值 + T7 档位
-- 值进指纹是因为选项键盘"当前档高亮"要跟着数据走（档位在别处改了也得重画）。
-- @param data table
-- @return string
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
