--------------------------------------------------------------------------------
-- frontend/charts.lua
--------------------------------------------------------------------------------
-- 【职责】图表绘制：点阵网格 / 折线 / 柱状（v2 的 plot + line + bar 合成一个文件）
-- 【不做什么】不取数据（数据由面板从 viewmodel 拿来）、不做业务判断
-- 【依赖】frontend/{state,theme,widgets}、shared/{utils,logs}、unicode
-- 【被谁用】frontend/panels/chart
--
-- 【版面】左侧留一列固定宽度的刻度位（charts.GUTTER）：上界 / 零轴 0 / 下界三个数字写在
--   坐标轴正左边、靠位置区分含义，画布整体右移让位；数字一律过 `charts.fitNumber` 限长。
--
-- 合成一个文件：v2 拆成 plot/line/bar 三个文件，而三者只有"画布计算"这一处共用；
--   合在一起后"网格 + 折线 + 柱"一目了然。
--------------------------------------------------------------------------------

local utils        = require("shared.utils")
local unicode      = require("unicode")
local logs         = require("shared.logs")

local fstate       = require("frontend.state")
local theme        = require("frontend.theme")
local widgets      = require("frontend.widgets")

local charts       = {}

charts.PAD_X       = 2
charts.PAD_Y       = 1
-- 刻度位宽度：坐标数字占坐标轴正左边这一列；画布（charts.metrics）整体右移同样列数。
--   7 列 = 常规最长形（"-1.23P"，6 列）+ 1 列与轴的空隙；再长由 fitNumber 去小数/截断。
--   不写"上/下"字样：数字就在对应行上，位置已说明含义，挂两个字只会把刻度位撑到 9 列。
charts.GUTTER      = 7

-- 越界检查：只在第一次发现时写一行日志（避免每帧刷屏）
local boundsWarned = false

--- 数字 -> **限长**文本：坐标/数值标签的唯一入口
-- 依次尝试：标准短单位（1.23G）-> 去小数（1G）-> 截断加 …。
-- 现场数据什么值都可能有：不夹住会顶破预留刻度位（把坐标轴挤歪），或让相邻柱的标签叠在一起。
-- @param value number|nil
-- @param w number 允许列数
-- @return string
function charts.fitNumber(value, w)
    w          = math.max(1, math.floor(w or 1))
    local text = utils.formatShortNumber(value or 0)
    if unicode.wlen(text) <= w then return text end
    local short = (text:gsub("%.%d+", "")) -- "-1.23G" -> "-1G"
    if unicode.wlen(short) <= w then return short end
    return unicode.sub(short, 1, math.max(0, w - 1)) .. "…"
end

--- 左侧刻度位写一个数字（右对齐贴着轴；限长到刻度位宽度）
-- @param area table 面板矩形
-- @param y number 行
-- @param value number|nil
-- @param color number
local function gutterLabel(area, y, value, color)
    widgets.drawTextRight(area.x + 1, charts.GUTTER, y,
        charts.fitNumber(value, charts.GUTTER), color)
end

--- 检查一次绘制用到的坐标是否超出画布；超了就写一行日志（只写一次）
-- 越界时让程序把真实坐标报出来（"屏幕上越界了"很难用语言描述清楚），
--   一轮实机就能定位（用户两次反馈“条长度越界”，靠猜浪费了两轮）。
-- @param tag string 图形名（柱状图 / 折线）
-- @param x0, y0, w, h number 画布
-- @param minY, maxY, maxX number 实际用到的纵向最小/最大、横向最大
function charts.checkBounds(tag, x0, y0, w, h, minY, maxY, maxX)
    if boundsWarned then return end
    if maxX > x0 + w - 1 or maxY > y0 + h - 1 or minY < y0 then
        boundsWarned = true
        logs.warn(string.format(
            "%s 绘制越界：画布 x=%d..%d y=%d..%d，实际用到 x..%d y=%d..%d（面板可能太窄）",
            tag, x0, x0 + w - 1, y0, y0 + h - 1, maxX, minY, maxY))
    end
end

--- 画布矩形（去掉内边距、左侧刻度位与底部一行刻度位）
-- 【高度为什么是 area.h - 5】纵向从上到下：边框(1) + 标题(1) + 说明行(1) → 画布 h 行 →
--   刻度/标签 1 行 → 下边框。旧版 h = area.h - 6 会在标签下多留一行空白（用户反馈"不够贴底"）。
-- 【宽度为什么要减 GUTTER】左侧留出固定列放坐标数字（上界 / 零轴 / 下界）——
--   旧版写在右上角，跟图名抢位置、也离坐标轴太远。
-- @param area table 面板矩形
-- @param yOffset number|nil 额外顶部偏移
-- @return number x0, y0, w, h
function charts.metrics(area, yOffset)
    local x0 = area.x + charts.PAD_X + 1 + charts.GUTTER
    local y0 = area.y + charts.PAD_Y + 2 + (yOffset or 0)
    local w  = area.w - charts.PAD_X * 2 - 2 - charts.GUTTER
    local h  = area.h - 5
    return x0, y0, w, h
end

--- 清空画布
function charts.clear(x0, y0, w, h)
    fstate.gpu.setBackground(theme.COLORS.BG)
    fstate.gpu.fill(x0, y0, w, h, " ")
end

--- 网格 + 坐标轴
-- @param x0, y0, w, h number
-- @param rows number|nil 横线数（默认 4）
function charts.grid(x0, y0, w, h, rows)
    if w < 8 or h < 4 then return end
    rows = rows or 4
    fstate.gpu.setForeground(theme.CHART_GRID)
    for i = 1, rows - 1 do
        local y = y0 + math.floor(h * i / rows)
        for x = 0, w - 1 do fstate.gpu.set(x0 + x, y, "·") end
    end
    fstate.gpu.setForeground(theme.CHART_AXIS)
    for x = 0, w - 1 do fstate.gpu.set(x0 + x, y0 + h - 1, "─") end
    for y = 0, h - 1 do fstate.gpu.set(x0 - 1, y0 + y, "│") end
    fstate.gpu.set(x0 - 1, y0 + h - 1, "└")
end

--- 数值序列 -> 画布坐标
-- @param values table
-- @param x0, y0, w, h number
-- @param fixedMin number|nil 指定量纲下限（多条曲线共用一套轴时传）
-- @param fixedMax number|nil 指定量纲上限
-- @return table 点数组
-- @return number minVal
-- @return number maxVal
function charts.project(values, x0, y0, w, h, fixedMin, fixedMax)
    local n = #values
    -- 【手写最值】不用 math.min(table.unpack(...))：跨版本/大数组都不安全
    local minVal, maxVal = fixedMin, fixedMax
    if minVal == nil or maxVal == nil then
        minVal, maxVal = values[1], values[1]
        for i = 2, n do
            local v = values[i]
            if v < minVal then minVal = v end
            if v > maxVal then maxVal = v end
        end
    end
    if minVal == maxVal then maxVal = minVal + 1 end

    local points = {}
    for i = 1, n do
        local px = x0 + math.floor((i - 1) / math.max(1, n - 1) * (w - 1))
        local py = y0 + h - 1 - math.floor((values[i] - minVal) / (maxVal - minVal) * (h - 1))
        points[i] = { x = px, y = py }
    end
    return points, minVal, maxVal
end

--- 折线图
-- @param area table 面板矩形
-- @param series table { { values = {..}, color = number, label = string }, .. }
-- @param times table 时刻数组（os.time，与各 values 等长）
-- @param title string 左上角说明
-- @return boolean 是否真的画了数据
function charts.series(area, series, times, title)
    local x0, y0, w, h = charts.metrics(area)
    if w < 8 or h < 4 then return false end
    charts.clear(x0, y0, w, h)
    charts.grid(x0, y0, w, h)

    -- 先把所有曲线拧到**同一量纲**上（都是 mB，直接比大小就是对的），再逐条投影
    local minVal, maxVal, drawable = nil, nil, 0
    local valid = {}
    for _, line in ipairs(series) do
        local values = line.values or {}
        if #values >= 2 then
            drawable = drawable + 1
            valid[#valid + 1] = line
            for i = 1, #values do
                local v = values[i]
                if minVal == nil or v < minVal then minVal = v end
                if maxVal == nil or v > maxVal then maxVal = v end
            end
        end
    end

    if drawable == 0 then
        widgets.drawText(x0, y0 - 1, title, theme.COLORS.TEXT_CYAN)
        widgets.drawCenteredTip({ x = x0, y = y0, w = w, h = h }, "数据采集中…（每 30 秒一个点）")
        return false
    end

    local minUsedY, maxUsedY, maxUsedX = y0, y0, x0
    for _, line in ipairs(valid) do
        local points = charts.project(line.values, x0, y0, w, h, minVal, maxVal)
        fstate.gpu.setForeground(line.color or theme.CHART_WATER)
        for i = 1, #points - 1 do
            local p1, p2 = points[i], points[i + 1]
            local steps = math.max(1, math.abs(p2.x - p1.x))
            for s = 0, steps do
                local x = p1.x + math.floor((p2.x - p1.x) * s / steps)
                local y = p1.y + math.floor((p2.y - p1.y) * s / steps)
                fstate.gpu.set(x, y, "█")
                minUsedY = math.min(minUsedY, y)
                maxUsedY = math.max(maxUsedY, y)
                maxUsedX = math.max(maxUsedX, x)
            end
        end
    end
    charts.checkBounds("折线", x0, y0, w, h, minUsedY, maxUsedY, maxUsedX)

    -- 【说明放标题行】左边图名；**上/下界不再写这里**，已搬到轴的左边刻度位
    widgets.drawText(x0, y0 - 1, title, theme.COLORS.TEXT_CYAN)
    -- 左侧刻度位：上面那个数 = 最大，下面那个数 = 最小（自适应范围，不是对称的 ±）
    gutterLabel(area, y0, maxVal, theme.COLORS.TEXT_YELLOW)
    gutterLabel(area, y0 + h - 1, minVal, theme.COLORS.TEXT_YELLOW)

    -- 横轴：首 / 中 / 尾三个时间标签（相对现在）
    local now = os.time()
    local n   = #times
    if n >= 2 then
        for _, index in ipairs({ 1, math.floor(n / 2) + 1, n }) do
            local point = charts.pointAt(index, n, x0, w)
            local diff  = now - (times[index] or now)
            local text
            if index == n then
                text = "现在"
            elseif diff < 60 then
                text = "刚刚"
            elseif diff < 3600 then
                text = string.format("-%d 分", math.floor(diff / 60))
            else
                text = string.format("-%d 时", math.floor(diff / 3600))
            end
            local labelX = point - math.floor(unicode.wlen(text) / 2)
            labelX = math.max(x0, math.min(labelX, x0 + w - unicode.wlen(text)))
            widgets.drawText(labelX, y0 + h, text, theme.COLORS.TEXT)
        end
    end
    return true
end

--- 把上界取整到"好看的刻度"（1 / 2 / 5 × 10^n）
-- 刻度用 formatShortNumber 显示：它对小于 1000 的数直接 math.floor，
--   于是 ±1.1 会显示成 "1 / -2"（floor(-1.1) = -2）——
--   用户看到的上下界不对称、还眼柱子对不上（2026-09-27 实机反馈的"越界"就是这个）。
--   取整到 1/2/5 阶梓后，刻度总是干净的整数，柱子比例也不会失真。
-- @param v number 正数
-- @return number
local function niceCeil(v)
    if v <= 0 then return 1 end
    -- 【不用 log10】Lua 5.4 已删掉它，用 log 又要防浮点误差（log(1000)/log(10) = 2.9999…）。
    --   循环找"不超过 v 的最大 10 的幂"最干净，最多几十次而已。
    local pow = 1
    while pow * 10 <= v do pow = pow * 10 end
    local frac = v / pow
    local step = (frac <= 1) and 1 or (frac <= 2) and 2 or (frac <= 5) and 5 or 10
    return step * pow
end

--- 柱状图：一根柱一个值（可正可负），**零轴固定**、上下对称自适应
-- 【用途】「全部」视图：横轴 = T1..T8，柱高 = 该级在时间窗口内的水量变化量
-- @param area table 面板矩形
-- @param values table 数值数组（可正可负）
-- @param labels table 每根柱下方的标签（与 values 等长）
-- @param title string 左上角说明
-- @return boolean 是否真的画了
function charts.bars(area, values, labels, title)
    local x0, y0, w, h = charts.metrics(area)
    if w < 8 or h < 4 then return false end
    charts.clear(x0, y0, w, h)
    charts.grid(x0, y0, w, h)

    local n = #values
    if n == 0 then return false end

    -- 【零轴固定】纵轴**上下对称**：零轴永远在画布正中，
    --   水量变化时只改“每格代表多少”，基准线不再上下乱跑。
    --   旧实现把 0 当最小值再加上余量 → 零轴贴底、柱子从底向上长，看着就像“越界”。
    local extreme = 0
    for i = 1, n do
        local v = values[i] or 0
        if math.abs(v) > extreme then extreme = math.abs(v) end
    end
    local bound = niceCeil(extreme * 1.05) -- 留一点余量再取整，保证柱子不会顶到边框
    local minVal, maxVal = -bound, bound

    -- 【最后一行留给坐标轴】投影到 y0..y0+h-2：否则负值最大的那根柱会把底部轴线整行盖住
    --   （看着就是"越界"）。零轴仍在画布中线附近，刻度含义不变。
    local span = maxVal - minVal
    local function yOf(v)
        return y0 + h - 2 - math.floor((v - minVal) / span * (h - 2))
    end
    local zeroY = yOf(0)

    -- 零轴（先画，柱覆盖其上）
    fstate.gpu.setForeground(theme.CHART_AXIS)
    for x = 0, w - 1 do fstate.gpu.set(x0 + x, zeroY, "─") end

    -- 【格子宽度】按画布均分；太窄时退回 3 列宽（宁可挤，也不画到面板外）
    local cellW = math.floor(w / n)
    if cellW < 3 then cellW = 3 end
    local barW                         = math.max(1, math.min(cellW - 2, w))
    local rooms                        = (cellW >= 6) -- 格子够宽才写数值，否则只留标签

    -- 【越界检查】画完对一次坐标：真的超出画布就把范围写进日志（只写一次）。
    --   “屏幕上越界了”这句话很难描述清楚，让程序自己报数字，一轮就能定位。
    local minUsedY, maxUsedY, maxUsedX = y0, y0, x0

    for i = 1, n do
        local v      = values[i] or 0
        local barX   = x0 + (i - 1) * cellW + math.floor((cellW - barW) / 2)
        barX         = math.max(x0, math.min(barX, x0 + w - barW)) -- 左右边界都夹住
        local valueY = yOf(v)
        local top    = math.max(y0, math.min(zeroY, valueY))
        local bottom = math.min(y0 + h - 1, math.max(zeroY, valueY))
        local rowH   = math.max(1, bottom - top + 1)
        local color  = (v >= 0) and theme.CHART_WATER or theme.COLORS.TEXT_RED

        -- 【值 = 0 就不画柱】零轴本身就是 0：再画一个 1 格高的"柱子"会让人以为
        --   "每级都有变化"。
        if v ~= 0 then
            fstate.gpu.setBackground(color)
            fstate.gpu.fill(barX, top, barW, rowH, " ")
            fstate.gpu.setBackground(theme.COLORS.BG)
            minUsedY = math.min(minUsedY, top)
            maxUsedY = math.max(maxUsedY, top + rowH - 1)
        end
        maxUsedX     = math.max(maxUsedX, barX + barW - 1)

        local label  = tostring(labels[i] or "")
        local labelX = x0 + (i - 1) * cellW + math.floor((cellW - unicode.wlen(label)) / 2)
        labelX       = math.max(x0, math.min(labelX, x0 + w - unicode.wlen(label)))
        widgets.drawText(labelX, y0 + h, label, theme.COLORS.TEXT)
        maxUsedX = math.max(maxUsedX, labelX + unicode.wlen(label) - 1)

        if rooms then
            -- 【限长到本格宽度】数字太长就缩/截，绝不压到隔壁柱的标签上
            local text = charts.fitNumber(v, cellW)
            -- 负向数字写在柱下方；下方已经没位置（柱已到底）就改写在零轴上方，不挤到轴线上
            local ty   = (v >= 0) and (top - 1) or (top + rowH)
            if ty > y0 + h - 2 then ty = top - 1 end
            ty          = math.max(y0, math.min(y0 + h - 2, ty))
            local textX = x0 + (i - 1) * cellW + math.floor((cellW - unicode.wlen(text)) / 2)
            textX       = math.max(x0, math.min(textX, x0 + w - unicode.wlen(text)))
            widgets.drawText(textX, ty, text, color)
            maxUsedX = math.max(maxUsedX, textX + unicode.wlen(text) - 1)
        end
    end

    charts.checkBounds("柱状图", x0, y0, w, h, minUsedY, maxUsedY, maxUsedX)

    -- 坐标信息在轴的左边：上界 / 零轴 0 / 下界三个数右对齐贴着轴，
    --   含义靠“写在轴的哪一行”表达，不写文字；数字一律走 fitNumber 限长。
    gutterLabel(area, y0, bound, theme.COLORS.TEXT_YELLOW)
    gutterLabel(area, zeroY, 0, theme.COLORS.CHART_AXIS)
    gutterLabel(area, y0 + h - 2, -bound, theme.COLORS.TEXT_YELLOW)
    return true
end

--- 第 i 个采样点（共 n 个）在画布上的 x 坐标
-- 单独抽出来：时间标签的位置不需要知道 y（也就不必重新投影一次）
-- @param index number 1 起
-- @param n number 总点数
-- @param x0, w number 画布
-- @return number
function charts.pointAt(index, n, x0, w)
    if n <= 1 then return x0 end
    return x0 + math.floor((index - 1) / (n - 1) * (w - 1))
end

return charts
