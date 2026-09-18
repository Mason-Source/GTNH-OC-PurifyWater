--------------------------------------------------------------------------------
-- frontend/panels/detail.lua
--------------------------------------------------------------------------------
-- 【职责】单级净水单元详情：**画在净水状态那块矩形里**（不占整屏），点任意处返回
-- 【不做什么】不登记热区（进/返回由 input 按 fstate.areas.status 判定）；不判断业务
-- 【依赖】frontend/{state,theme,widgets,layout}、shared/{constants,utils}、unicode
-- 【被谁用】frontend/panels/status（详情态时把这块矩形交给它画）
--
-- 【显示什么】
--   ① 基础：单并行功耗 / 已部署机器数
--   ② 建议（公式推算）：每台并行 / 每台功耗 / 全开总功耗
--   ③ 当前功耗：只留当前等级总功耗
--   ④ 每台机器：序号 | 当前并行 | 真实并行 | 当前成功率（按列宽补齐）
-- 【三个"并行"】当前并行 = sample（本周期读到、未确认）｜ 真实并行 = parallel（连续 N 个运行周期
--   一致 -> tracker 确认 -> 落盘）｜ 建议并行 = power.suggest（公式）。三者都逐台可见。
-- 【陈旧怎么标】没在跑时"当前"那个数就是上次运行留下的 -> 值后面跟 `(上次运行)`（不清零）。
-- 【排版】只用工程里已经在用的符号：分隔线 `─`、项目符号 `·`（与 drawBorder 的 ┌─┐│└┘ 同族）；
--   OC 字体里没验证过的字符不上屏。
--------------------------------------------------------------------------------

local unicode   = require("unicode")

local constants = require("shared.constants")
local utils     = require("shared.utils")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")

local detail    = {}

-- 项目符号与分隔线（两处都用，避免各写一遍）
local BULLET    = "· "
local RULE      = "─"

--- 一条分隔线（带小标题）：`─ 建议 ──────────────`
-- @param x, y number
-- @param w number 可用宽度
-- @param text string 小标题（可为 ""）
local function ruleLine(x, y, w, text)
    local head = (text ~= "") and (" " .. text .. " ") or ""
    widgets.drawText(x, y, RULE .. head .. string.rep(RULE, math.max(0, w - unicode.wlen(head) - 1)),
        theme.COLORS.TEXT_DISABLED)
end

--- 逐台机器那几行：**严格对齐**的表格（序号 | 当前并行 | 真实并行 | 当前成功率）
-- 列宽取本表里最宽的那一格：数值长度不一（3,000,000 vs 499,999、#1 vs #10），不补空格就会参差。
-- 每列前缀宽度一致、数值右对齐，一眼能比大小。
-- 列名写全（"当前并行 / 真实并行"）：只写"当前 / 真实"语义不明 —— 这里三个数都是并行，还有成功率。
-- 【三个数的来源】当前并行 = fact.parallel（本周期传感器读数，没在跑写"停"）；
--   真实并行 = tracker 确认值，没确认过就用本级记录值；成功率 = 传感器那次读到的。
-- @param machines table api.read.levels() 的 machines
-- @param record number|nil 本级记录的并行（机器还没单独确认时的兼底）
-- @return table 行数组 { { 左列, 右列, 颜色 }, ... }
local function machineRows(machines, record)
    local num                      = utils.formatNumber
    local list, curW, realW, rateW = {}, 0, 0, 0

    -- ① 先拼好每台的三段，顺便量出各列最宽
    for index, m in ipairs(machines or {}) do
        local running      = (m.active == true)
        local cur          = running and (m.current and num(m.current) or "-") or "停"
        local realVal      = m.confirmed or record
        local real         = realVal and num(realVal) or "-"
        local rate         = m.success and (tostring(m.success) .. "%") or "-"
        list[#list + 1]    = { index, cur, real, rate, running }
        curW, realW, rateW = math.max(curW, unicode.wlen(cur)),
            math.max(realW, unicode.wlen(real)), math.max(rateW, unicode.wlen(rate))
    end

    -- ② 按列宽补齐（前缀 + 右对齐数值），段间三个空格
    local function cell(prefix, value, width)
        return prefix .. string.rep(" ", math.max(0, width - unicode.wlen(value))) .. value
    end
    local out = {}
    for _, item in ipairs(list) do
        out[#out + 1] = {
            string.format("%s#%d", BULLET, item[1]),
            table.concat({
                cell("当前并行 ", item[2], curW),
                cell("真实并行 ", item[3], realW),
                cell("成功率 ", item[4], rateW)
            }, "   "),
            item[5] and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED
        }
    end
    return out
end

--- 正文行：{ 类型, 左列, 右列, 颜色 }；类型 "rule" = 分隔线，"item" = 数据行
-- @param row table api.read.levels() 的一级
-- @param level number
-- @return table
local function lines(row, level)
    local per      = constants.POWER_LEVELS[level] or 0
    local deployed = row.deployed or 0
    local suggest  = row.suggest or 0
    local running  = (row.active or 0) > 0
    -- 不做 K/M/G 缩写，写完整值（千分位只为了好读）
    local num      = utils.formatNumber
    -- 没在跑 -> 这些"当前"值是上次运行留下的，标一下（不清零）
    local stale    = running and "" or "  (上次运行)"
    local liveWatt = running and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT_DISABLED

    local out      = {}
    local function sep(text)
        out[#out + 1] = { "rule", text, "", theme.COLORS.TEXT_DISABLED }
    end
    local function item(label, value, color)
        out[#out + 1] = { "item", BULLET .. label, value, color }
    end

    sep("基础")
    item("单并行功耗", num(per) .. " EU/t", theme.COLORS.TEXT)
    item("已部署机器", tostring(deployed) .. " 台", theme.COLORS.TEXT)

    sep("建议（公式推算）")
    item("每台并行", num(suggest), theme.COLORS.TEXT_CYAN)
    item("每台功耗", num(suggest * per) .. " EU/t", theme.COLORS.TEXT_CYAN)
    item("全开总功耗", num(suggest * per * deployed) .. " EU/t", theme.COLORS.TEXT_CYAN)

    -- 当前段只留总功耗（逐台那两行已经写了并行）
    sep("当前功耗")
    local perPower = row.sample and (row.sample * per) or nil
    item("当前等级总功耗", perPower and (num(perPower * deployed) .. " EU/t" .. stale) or "-", liveWatt)

    sep("每台机器")
    for _, machineRow in ipairs(machineRows(row.machines, row.parallel)) do
        out[#out + 1] = { "item", machineRow[1], machineRow[2], machineRow[3] }
    end
    return out
end

--- 画这一级的详情（矩形由 status 面板传进来 = 净水状态那块）
-- @param data table vm.build() 的返回
-- @param area table { x, y, w, h }
function detail.draw(data, area)
    local level = fstate.detailLevel
    local row   = level and data.levels[level] or nil

    widgets.clearArea(area.x, area.y, area.w, area.h)
    widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(data.system.priority == "high"))

    if not row then
        widgets.drawText(area.x + 2, area.y + 1, "净水单元详情：没有选中等级（点某一行进来）",
            theme.COLORS.TEXT_YELLOW)
        return
    end

    -- 标题行：等级 + 返回提示（详情只占这一块，行数要省给数据）
    widgets.drawText(area.x + 2, area.y + 1,
        string.format("净水单元详情 · %s", row.label), theme.COLORS.TEXT_CYAN)
    widgets.drawTextRight(area.x + 2, area.w - 4, area.y + 1, "← 点任意处返回", theme.COLORS.TEXT_DISABLED)

    -- 两列（左标签右值）：列位交给 layout，换分辨率不会错位。右列给 74%：
    --   逐台那些行是三段固定宽度的表（14 位数字 × 2 + 成功率），窄了会被截断；
    --   左列最长标签 "· 当前等级总功耗" = 16 列，21 列够用。
    local cols  = layout.cols({ x = area.x + 2, w = area.w - 4 }, { 0.26, 0.74 })
    local rows  = lines(row, level)
    local top   = area.y + 2
    local last  = area.y + area.h - 2
    local drawn = 0

    for _, item in ipairs(rows) do
        local y = top + drawn
        if y > last then break end
        if item[1] == "rule" then
            ruleLine(cols[1].x, y, cols[1].w + cols[2].w, item[2])
        else
            local value = tostring(item[3])
            if unicode.wlen(value) > cols[2].w then
                value = unicode.sub(value, 1, math.max(1, cols[2].w - 1)) .. "…"
            end
            widgets.drawText(cols[1].x, y, tostring(item[2]), theme.COLORS.TEXT_DISABLED)
            widgets.drawText(cols[2].x, y, value, item[4])
        end
        drawn = drawn + 1
    end

    -- 屏高不够就说一声（别静默丢行：看不到的机器台数也是信息）
    if drawn < #rows and top + drawn <= last then
        widgets.drawText(cols[1].x, top + drawn,
            string.format("…（屏高不够，还有 %d 行）", #rows - drawn), theme.COLORS.TEXT_YELLOW)
    end
end

--- 指纹：选中等级 + 这一页会画的每个数 + 边框色依据 + 矩形尺寸
-- priority 决定边框色；矩形尺寸决定能画几行（换分辨率 / 面板高度变了要重画）。
-- @param data table
-- @return string
function detail.fingerprint(data)
    local level = fstate.detailLevel or 0
    local row   = data.levels[level] or {}
    local parts = {
        tostring(level), tostring(row.label), tostring(data.system.priority),
        tostring(fstate.areas.status and fstate.areas.status.w or 0),
        tostring(fstate.areas.status and fstate.areas.status.h or 0),
        tostring(row.deployed), tostring(row.active), tostring(row.sample),
        tostring(row.parallel), tostring(row.suggest)
    }
    for _, machine in ipairs(row.machines or {}) do
        parts[#parts + 1] = tostring(machine.address) .. ":" .. tostring(machine.active)
            .. ":" .. tostring(machine.current) .. ":" .. tostring(machine.confirmed)
            .. ":" .. tostring(machine.success)
    end
    return table.concat(parts, "\x1f")
end

return detail
