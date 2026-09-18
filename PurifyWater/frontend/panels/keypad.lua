--------------------------------------------------------------------------------
-- frontend/panels/keypad.lua
--------------------------------------------------------------------------------
-- 【职责】配置页的**键盘本体**：三段虚拟键盘（数字 / 倍数 / 档位）
-- 【不做什么】不画列表（panels/config）、不画输入回显（panels/editline）、不碰后端（提交在 input）
-- 【依赖】frontend/{state,theme,widgets}
-- 【被谁用】frontend/render
--
-- 【配置页分三块，各管各的指纹】
--     config   列表 —— 只认 勾选 / 阈值 / 选中
--     editline 回显 —— 只认 选中 + 缓冲（每敲一个键只有这一行动）
--     keypad   键盘 —— 只认 选中（键的灰/亮只由"改谁"决定，与敲的数字无关）
--   原来是一整块：点一下键盘连 8 行列表一起重画，屏幕上就是闪一下。
-- 【单位 kL】缓冲是**纯数字串**（不带逗号、不带单位）；单位只在列表表头写一次。
-- 【三段键盘】
--   数字 0-9 / ← 退格 / C 清空 / ✔ 确定 / ✘ 取消  —— 基本编辑
--   x2 x10 x100 x1000 / /2 /10 /100 /1000          —— 倍数（跨数量级最省点击；能乘也能除）
--   1k … 100G 1T 10T                                —— 档位直选（1e3 ~ 1e13 kL，盖住输入上限）
--   =上级                                            —— 抄上一级（8 级通常同一数量级）
--   【不做】长按连发 / 单位切换 / 实时判定预览
--------------------------------------------------------------------------------

local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")

local keypad  = {}

-- 键盘几何（数值只在这里）
local KEY_W   = 8
local KEY_GAP = 2
local SEP     = 3 -- 段间空隙（含分隔符那一列）

-- 三段键盘：行 × 列，每键 = { 显示文本, 语义 kind, 参数 value }
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

--- 这个键现在能不能按（都要先选中某级；"抄上级"还要真的有上一级）
-- @param kind string
-- @return boolean
local function keyEnabled(kind)
    if not fstate.configSel then return false end
    if kind == "copy" and fstate.configSel <= 1 then return false end
    return true
end

--- 一个键的文字颜色（功能键分色，一眼能找到）
local function keyColor(kind)
    if kind == "commit" then return theme.COLORS.TEXT_GREEN end
    if kind == "cancel" then return theme.COLORS.TEXT_DISABLED end
    if kind == "copy" then return theme.COLORS.TEXT_YELLOW end
    if kind == "mul" or kind == "div" then return theme.COLORS.TEXT_YELLOW end
    if kind == "set" then return theme.COLORS.TEXT_CYAN end
    return theme.COLORS.TEXT
end

--- 一张键盘表要占多宽（不画，先量）
-- @param rows table 行 × 列
-- @return number
local function padWidth(rows)
    local cols = 0
    for _, row in ipairs(rows) do cols = math.max(cols, #row) end
    return cols * (KEY_W + KEY_GAP) - KEY_GAP
end

--- 画一张键盘表并登记热区
-- @param x, y number 左上角
-- @param rows table 行 × 列
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
                    -- 热区里直接带语义：input 不必认识键盘长什么样
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

    -- 三段排开、整体居中：先量出三段宽度，算好它们在面板里均匀落位；段间竖一条分界线
    --   （四行都画，看起来才是一根线）。
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

--- 指纹：面板尺寸 + 选中
-- 不带 configBuf：键的灰/亮只由"改谁"决定，敲数字不该让键盘重画。
function keypad.fingerprint(data)
    local area = fstate.areas.keypad
    return table.concat({
        tostring(area and area.w or 0), tostring(area and area.h or 0),
        tostring(fstate.configSel or 0)
    }, "\x1f")
end

return keypad
