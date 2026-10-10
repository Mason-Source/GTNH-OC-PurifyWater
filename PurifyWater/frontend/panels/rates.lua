--------------------------------------------------------------------------------
-- frontend/panels/rates.lua
--------------------------------------------------------------------------------
-- 【职责】配置页「速率权重」卡片：左边表格（级 / 权重 / 建议并行）+ 右边它自己的键盘 + 子项一行
--   （T7 增产倍率）。点某级选中 -> 输入的权重缓冲显示在该行的"权重"列（带下划线）。
-- 【不做什么】不碰后端（提交由 input 发 weight_set / t7_boost_cycle）、
--   不画阈值卡与运行设置卡、不判断能不能点（热区登记与否只在这里一处决定）
-- 【依赖】frontend/{state,theme,widgets,layout}、shared/{constants,config}
-- 【被谁用】frontend/render（配置页面板表）
--
-- 【版面】卡片整高 14：边框 2 + 标题 1 + 表头 1 + 8 级 + 子项 2（T7 增产倍率行前空 1 行）。
--   「阈值约束」不在本卡：它和"高低优先级"一样，是**当前模式的子参数**，只在总览页「模式」行右侧切。
--   卡内左右分栏：
--   表格在左（约 62%），键盘在右（4×4：数字 0-9 + ← 退格 + C 清空 + ✔ 保存 + ✘ 取消）。
--   键盘只在"选中了某一级"时才登记热区（灰着 = 点了没反应，与阈值卡同一套约定）。
-- 【建议并行列】显示**当前调度模式**算出来的建议（阈值模式 = 满功率公式；速率模式 = 权重链）。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local CONFIG    = require("shared.config")

local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")

local rates     = {}

-- 键盘几何（数值只在这里）
local KEY_W     = 8
local KEY_GAP   = 2

-- 4×4 键盘：数字 + 动作（空位 nil，画的时候跳过）
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

    -- 卡内左右分栏：左表格 / 右键盘
    local inner  = { x = area.x + 2, w = math.max(0, area.w - 4) }
    local halves = layout.cols(inner, { 0.62, 0.38 })
    local left, right = halves[1], halves[2]

    -- ① 左表格：级 / 权重 / 建议并行
    local cols   = layout.cols(left, { 0.16, 0.26, 0.58 })
    local headY  = area.y + 2
    local lastY  = area.y + area.h - 3 -- 子项行（T7 增产倍率）的上一行
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

    -- ② 右键盘（没选中某级时全部灰着、不登记热区）
    local keypadW = 4 * KEY_W + 3 * KEY_GAP
    local keypadX = right.x + math.max(0, math.floor((right.w - keypadW) / 2))
    local keypadY = area.y + 2
    local enabled = (fstate.rateSel ~= nil) and (right.w >= keypadW) -- 右列放不下就不画键盘（不越界）
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

    -- ③ 子项行（贴卡底）：T7 增产倍率（"阈值约束"在总览页模式行，不在这里）
    local boostY = area.y + area.h - 2
    fstate.rateBoostRow = { x = area.x + 2, y = boostY, w = area.w - 4, h = 1 }
    widgets.drawText(area.x + 2, boostY,
        string.format("T7 增产倍率：×%s（点这一行切换 1 / 1.25 / 1.5 / 1.75 / 2）",
            tostring(sys.t7Boost or 1)), theme.COLORS.TEXT)
end

--- 指纹：尺寸 + 模式/子参数 + 每级（权重/建议/名字）+ 选中与缓冲
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
