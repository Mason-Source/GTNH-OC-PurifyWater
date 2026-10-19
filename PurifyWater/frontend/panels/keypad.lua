--------------------------------------------------------------------------------
-- frontend/panels/keypad.lua
--------------------------------------------------------------------------------
-- 【职责】调度配置卡内的固定键盘槽：按选中列换键盘
--   threshold = 三段键盘；weight = 数字；boost = 复合收集选项键盘；
--   produce = 制作自动化面板（机器绑定 / 解绑 / 翻页 / 开关）；勾选不走这里。
-- 【不做什么】不画表格（panels/config）、不碰后端
-- 【依赖】unicode、frontend/{state,theme,widgets}
-- 【被谁用】frontend/render
--
-- 固定槽位置不动；槽首行为提示。缓冲为纯数字串，单位只在表头。
--------------------------------------------------------------------------------

local unicode = require("unicode")

local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local utils   = require("shared.utils")

local CONFIG    = require("shared.config")
local constants = require("shared.constants")

local keypad  = {}

-- 键位几何（数值只在这里）
local KEY_W   = 8  -- 普通键宽
local KEY_GAP = 3  -- 键间距（槽加高后放宽一点，按键更好点）
local SEP     = 3  -- 阈值键盘的段间空隙（含那条竖线）
local OPT_W   = 10 -- 选项键宽（"×1.25" 这类档位都放得下）

-- 阈值键盘：三段键盘，行 × 列，每键 = { 显示文本, 语义 kind, 参数 value }
-- kind 语义在 input.applyKey；这里只管长相与位置
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
--- 键盘表宽度（不画先量）
-- @param rows table 行 × 列
-- @return number
local function padWidth(rows)
    local cols = 0
    for _, row in ipairs(rows) do cols = math.max(cols, #row) end
    return cols * (KEY_W + KEY_GAP) - KEY_GAP
end

--- 键是否可点：需先选中列；抄上级需有上一级
-- @param field string 正在改的列
-- @param kind string 键的语义
-- @return boolean
local function keyEnabled(kind)
    if not fstate.editField then return false end
    if kind == "copy" and (fstate.editLevel or 1) <= 1 then return false end
    return true
end

--- 画键盘表并登记热区
-- 列数按满格算（含 nil 空位；带洞行 #row 不可靠），一律扫到 cols。
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
--- 档位文本：整数不带小数点
-- @param value number
-- @return string
local function numberText(value)
    value = tonumber(value) or 0
    if value == math.floor(value) then return string.format("%d", value) end
    return string.format("%g", value)
end

--- 槽内第一行提示
-- @param data table viewmodel 数据（取等级名与当前档位）
-- @return string
-- @return number 颜色
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
        local sys = (data and data.system) or {}
        if fstate.editLevel == 1 or fstate.editLevel == 2 then
            local on = type(sys.reflux) == "table" and sys.reflux[fstate.editLevel] == true
            return string.format("正在编辑 %s 回流数据收集（当前 %s）：点击切换",
                label, on and "开" or "关"), theme.COLORS.TEXT_YELLOW
        elseif fstate.editLevel == constants.T6_LEVEL then
            return string.format("正在编辑 T6 双锂数据收集（当前 %s）：点击切换",
                sys.t6DualLithium == true and "双锂" or "标准"), theme.COLORS.TEXT_YELLOW
        end
        return string.format("正在编辑 T7 增产倍率（当前 ×%s）：点击切换档位",
            numberText(sys.t7Boost)), theme.COLORS.TEXT_YELLOW
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

--- 侧位失败原因 -> 表格短文案（完整原因在调试日志；这里只求一眼看懂）
-- @param reason string|nil
-- @return string|nil
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

--- 截到列宽内（超宽右侧省略）
-- @param text string
-- @param width number
-- @return string
local function fitText(text, width)
    if unicode.wlen(text) <= width then return text end
    return unicode.sub(text, 1, math.max(1, width - 1)) .. "…"
end

--- 制作自动化面板（选中「制作自动化」列时占满键盘槽，不画提示行）
-- 第一行顶格：标题 + 就绪台数 +（翻页）+（开关）+（绑定中：提示 + 取消）
-- 下面：居中的表格（表头 + 机器行），列内一律左对齐
-- 列：# / 坐标 / 转运器 / 侧位 / 操作；侧位 = - / 自动配置中 / 失败·原因 / 配置就绪
-- 在网与否只看颜色（白 = 在网、灰 = 不在网）；未绑定 / 已绑离线 -> 灰 [绑定]，在网 -> [解绑]
-- @param area table 键盘槽矩形
-- @param data table viewmodel.build() 的返回
local function drawProduce(area, data)
    local level = fstate.editLevel or 1
    local pd    = (data and data.produce) or {}
    local info  = (pd.levels or {})[level] or { count = 0, online = 0, machines = {} }
    local list  = info.machines or {}
    local row   = ((data or {}).levels or {})[level]

    -- 预制列宽（整块居中；列内左对齐）
    local NUM_W, COORD_W, TARGET_W, SIDE_W, ACT_W, GAPW = 4, 20, 14, 18, 8, 2
    local blockW = NUM_W + COORD_W + TARGET_W + SIDE_W + ACT_W + GAPW * 4
    local bx     = area.x + math.max(0, math.floor((area.w - blockW) / 2))
    local xNum    = bx
    local xCoord  = xNum + NUM_W + GAPW
    local xTarget = xCoord + COORD_W + GAPW
    local xSide   = xTarget + TARGET_W + GAPW
    local xAct    = xSide + SIDE_W + GAPW

    -- 翻页（越界夹取；每页 = 槽高 - 2：第一行 + 表头）
    local perPage = math.max(1, area.h - 2)
    local pages   = math.max(1, math.ceil(#list / perPage))
    fstate.producePage = math.min(math.max(1, tonumber(fstate.producePage) or 1), pages)

    -- 第一行：顶格从左往右排（不右对齐）
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
    -- 就绪 = 转运器已绑定 且 侧位自动配置完成 的机器数
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

    -- 表头（左对齐）
    local hy = area.y + 1
    widgets.drawText(xNum, hy, "#", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xCoord, hy, "坐标", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xTarget, hy, "转运器", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xSide, hy, "侧位", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(xAct, hy, "操作", theme.COLORS.TEXT_DISABLED)

    -- 机器行：未绑定 / 已绑但离线 -> 灰 [绑定]；已绑在线 -> 白字地址 + [解绑]
    local first = (fstate.producePage - 1) * perPage + 1
    for index = 1, perPage do
        local ry   = hy + index
        local item = list[first + index - 1]
        if item and ry <= area.y + area.h - 1 then
            widgets.drawText(xNum, ry, tostring(first + index - 1), theme.COLORS.TEXT)
            widgets.drawText(xCoord, ry, unicode.sub(item.text or "-", 1, COORD_W), theme.COLORS.TEXT)

            -- 侧位自动配置：- / 自动配置中 / 失败·原因 / 配置就绪
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

--- 画键盘槽：提示行 + 当前列自己的键盘（键在剩下的行里垂直居中）
-- @param data table viewmodel.build() 的返回
function keypad.draw(data)
    local area = fstate.areas.keypad
    if not area or area.w <= 0 or area.h <= 0 then return end
    widgets.clearArea(area.x, area.y, area.w, area.h)
    fstate.keys = {}
    fstate.produceHits = {}
    if area.h < 2 then return end

    -- 制作自动化面板占满整槽（不画提示行：界面已足够直观）
    if fstate.editField == "produce" then
        drawProduce(area, data)
        return
    end

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
    elseif fstate.editField == "weight" or fstate.editField == "factor"
        or fstate.editField == "strength" then
        local kx = area.x + math.max(0, math.floor((area.w - padWidth(WEIGHTS)) / 2))
        -- 末行 4 键：右移半格居中
        drawPad(kx, slotY(#WEIGHTS), WEIGHTS, { [3] = math.floor((KEY_W + KEY_GAP) / 2) })
    elseif fstate.editField == "boost" then
        local sys     = (data and data.system) or {}
        local level   = fstate.editLevel
        local options = {}
        if level == 1 or level == 2 then
            local on = type(sys.reflux) == "table" and sys.reflux[level] == true
            options = {
                { label = "开", kind = "set_reflux", value = true, current = on },
                { label = "关", kind = "set_reflux", value = false, current = not on }
            }
        elseif level == constants.T6_LEVEL then
            local on = sys.t6DualLithium == true
            options = {
                { label = "标准", kind = "set_t6_dual", value = false, current = not on },
                { label = "双锂", kind = "set_t6_dual", value = true, current = on }
            }
        else
            local current = tonumber(sys.t7Boost) or 1
            for _, value in ipairs(constants.T7_BOOST_OPTIONS) do
                options[#options + 1] = {
                    label = "×" .. numberText(value), kind = "set_boost",
                    value = tostring(value), current = (value == current)
                }
            end
        end
        drawOptions(area.x, slotY(1), area.w, options)
    end
end

--- 指纹：槽尺寸 + 选中态 + 行值 + T7 档位
-- @param data table
-- @return string
function keypad.fingerprint(data)
    local area  = fstate.areas.keypad or {}
    local sys   = (data and data.system) or {}
    local parts = {
        tostring(area.x or 0), tostring(area.y or 0), tostring(area.w or 0), tostring(area.h or 0),
        tostring(fstate.editField or ""), tostring(fstate.editLevel or 0),
        tostring(fstate.editBuf or ""), tostring(sys.t7Boost),
        tostring(sys.t6DualLithium), tostring(type(sys.reflux) == "table" and sys.reflux[1] or nil),
        tostring(type(sys.reflux) == "table" and sys.reflux[2] or nil)
    }
    local row = (data and fstate.editLevel) and data.levels[fstate.editLevel]
    if row then
        parts[#parts + 1] = table.concat({
            tostring(row.rule.enabled), tostring(row.rule.threshold), tostring(row.weight)
        }, ":")
    end

    -- 制作自动化面板：翻页 + 该级机器绑定状态 + 绑定中状态（画什么就进什么）
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
