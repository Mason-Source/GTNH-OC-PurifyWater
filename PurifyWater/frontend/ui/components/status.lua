--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/status.lua
--
-- 定位：等级状态总览与单级详情组件。
-- 功能：绘制 T1-T8 开关、水量、并行、成功率和机器明细；周期条由独立组件绘制。
-- 边界：只展示 ViewModel，不读取硬件或业务状态。
--------------------------------------------------------------------------------

local Component = require("frontend.ui.base")
local constants = require("shared.constants")
local util = require("shared.util")
local Status = {}

--- 创建等级状态组件。
function Status.new()
    local self = Component.new("status", { levels = {} })
    self.fingerprint = Status.fingerprint
    self.render = Status.render
    return self
end

--- 生成等级状态、详情层级和尺寸的渲染指纹。
function Status:fingerprint(context)
    local parts = {
        self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h,
        context.themeId,
        tostring(context.ui.detailLevel or 0),
    }
    for level = 1, 8 do
        local row = self.props.levels[level] or {}
        parts[#parts + 1] = table.concat({
            tostring(row.label), tostring(row.switchText), tostring(row.waterOfText),
            tostring(math.floor((row.ratio or 0) * 100)), tostring(row.rateText),
            tostring(row.sample), tostring(row.sampleText), tostring(row.learned),
            tostring(row.suggestText), tostring(row.sampleRole), tostring(row.suggestRole),
            tostring(row.deployText), tostring(row.mark), tostring(row.running),
            tostring(row.active), tostring(row.deployed),
            tostring(row.rule and row.rule.userThreshold),
            tostring(row.rule and row.rule.effectiveThreshold),
            tostring(row.rule and row.rule.overridden),
        }, ":")
        for _, machine in ipairs(row.machines or {}) do
            parts[#parts + 1] = table.concat({
                tostring(machine.address), tostring(machine.active),
                tostring(machine.current), tostring(machine.confirmed),
                tostring(machine.success),
            }, ":")
        end
    end
    return table.concat(parts, "\x1f")
end

--- 计算周期条区域，并供状态组件和独立进度条组件共用。
function Status.layoutCycle(rect, measure)
    local title = "各级净水状态"
    local label = "运行周期 "
    local hint = "点某一级看详情 →"
    local titleY = rect.y + 1
    local labelX = rect.x + 3 + measure(title)
    local barX = labelX + measure(label)
    local pctW = 7
    local hintW = measure(hint)
    local pctX = rect.x + rect.w - 2 - pctW
    local hintShown = pctX - barX > hintW + 2
    if hintShown then
        pctX = rect.x + rect.w - 3 - hintW - pctW - 1
    end
    return {
        title = title,
        titleY = titleY,
        label = label,
        labelX = labelX,
        hint = hint,
        hintShown = hintShown,
        barX = barX,
        barW = math.max(0, pctX - barX - 1),
        pctX = pctX,
        pctW = pctW,
    }
end
local function columns(area, weights)
    local out, total = {}, 0
    for _, weight in ipairs(weights) do total = total + weight end
    if total <= 0 then total = 1 end
    local x, left = area.x, area.w
    for index, weight in ipairs(weights) do
        local width = (index == #weights) and left
            or math.floor(area.w * weight / total)
        out[index] = { x = x, w = width }
        x = x + width
        left = left - width
    end
    return out
end

local BULLET = "· "
local RULE = "─"

local function ruleLine(p, x, y, width, text)
    local head = text ~= "" and (" " .. text .. " ") or ""
    local line = RULE .. head .. string.rep(RULE, math.max(0, width - p:measure(head) - 1))
    p:text(x, y, line, "disabled", "surface")
end

local function machineRows(p, row)
    local list, currentW, learnedW, rateW = {}, 0, 0, 0
    local learnedFallback = tonumber(row.learned)

    for index, machine in ipairs(row.machines or {}) do
        local current = machine.active
            and (machine.current ~= nil and util.formatNumber(machine.current) or "-")
            or "停"
        local learnedValue = machine.confirmed or learnedFallback
        local learned = learnedValue ~= nil and util.formatNumber(learnedValue) or "-"
        local rate = machine.success ~= nil and (tostring(machine.success) .. "%") or "-"
        list[#list + 1] = { index, current, learned, rate, machine.active == true }
        currentW = math.max(currentW, p:measure(current))
        learnedW = math.max(learnedW, p:measure(learned))
        rateW = math.max(rateW, p:measure(rate))
    end

    local function cell(prefix, value, width)
        return prefix .. string.rep(" ", math.max(0, width - p:measure(value))) .. value
    end

    local out = {}
    for _, item in ipairs(list) do
        out[#out + 1] = {
            label = string.format("%s#%d", BULLET, item[1]),
            value = table.concat({
                cell("当前并行 ", item[2], currentW),
                cell("学习并行 ", item[3], learnedW),
                cell("成功率 ", item[4], rateW),
            }, "   "),
            role = item[5] and "success" or "disabled",
        }
    end
    return out
end

local function detailRows(p, row, level)
    local per = constants.POWER_LEVELS[level] or 0
    local deployed = tonumber(row.deployed) or 0
    local suggest = tonumber(row.suggest) or 0
    local running = (tonumber(row.active) or 0) > 0
    local stale = running and "" or "（上次运行）"
    local num = util.formatNumber
    local rows = {}
    local function powerOf(parallel, perParallel, machines)
        return (tonumber(parallel) or 0) * 1.0
            * (tonumber(perParallel) or 0) * (tonumber(machines) or 0)
    end

    local function separator(text)
        rows[#rows + 1] = { kind = "rule", text = text }
    end
    local function item(label, value, role)
        rows[#rows + 1] = { kind = "item", label = BULLET .. label, value = value, role = role or "text" }
    end

    separator("基础")
    item("单并行功耗", num(per) .. " EU/t")
    item("已部署机器", tostring(deployed) .. " 台")

    local rule = row.rule or {}
    local userThreshold = tonumber(rule.userThreshold)
    local actualThreshold = tonumber(rule.effectiveThreshold)
    local thresholdText
    if rule.overridden == true and userThreshold ~= nil and actualThreshold ~= nil then
        thresholdText = util.formatNumber(math.floor(userThreshold / 1000)) .. " kL → " .. util.formatNumber(math.floor(actualThreshold / 1000)) .. " kL"
    else
        thresholdText = util.formatNumber(math.floor((actualThreshold or 0) / 1000)) .. " kL"
    end
    item("实际阈值", thresholdText, rule.overridden == true and "warning" or "text")

    separator("建议")
    item("每台并行", num(suggest), "accent")
    item("每台功耗", num(powerOf(suggest, per, 1)) .. " EU/t", "accent")
    item("全开总功耗", num(powerOf(suggest, per, deployed)) .. " EU/t", "accent")

    separator("当前功耗")
    local perPower = tonumber(row.sample)
    local totalPower = perPower and powerOf(perPower, per, deployed) or nil
    item("当前等级总功耗", totalPower and (num(totalPower) .. " EU/t" .. stale) or "-",
        running and "warning" or "disabled")

    separator("每台机器")
    for _, machineRow in ipairs(machineRows(p, row)) do
        rows[#rows + 1] = { kind = "item", label = machineRow.label,
            value = machineRow.value, role = machineRow.role }
    end
    return rows
end

local function detail(self, context)
    local p = context.painter
    local r = self.rect
    local level = context.ui.detailLevel
    local row = self.props.levels[level]
    p:panel(r)

    if not row then
        p:text(r.x + 2, r.y + 1, "净水单元详情：没有选中等级（点某一行进来）",
            "warning", "surface", r.w - 4)
        context:hit({ type = "detail_back" }, { x = r.x + 1, y = r.y + 1, w = r.w - 2, h = r.h - 2 })
        return
    end

    local title = string.format("净水单元详情 · %s", row.label or ("T" .. level))
    p:text(r.x + 2, r.y + 1, title, "accent", "surface", r.w - 4)
    p:textRight(r.x + 2, r.y + 1, r.w - 4, "← 点任意处返回", "disabled", "surface")

    local cols = columns({ x = r.x + 2, w = math.max(1, r.w - 4) }, { 0.26, 0.74 })
    local rows = detailRows(p, row, level)
    local top = r.y + 2
    local last = r.y + r.h - 2
    local drawn = 0

    for _, item in ipairs(rows) do
        local y = top + drawn
        if y > last then break end
        if item.kind == "rule" then
            ruleLine(p, cols[1].x, y, cols[1].w + cols[2].w, item.text)
        else
            p:text(cols[1].x, y, item.label, "disabled", "surface", cols[1].w)
            p:text(cols[2].x, y, tostring(item.value), item.role, "surface", cols[2].w)
        end
        drawn = drawn + 1
    end

    if drawn < #rows and top + drawn <= last then
        p:text(cols[1].x, top + drawn,
            string.format("…（屏高不够，还有 %d 行）", #rows - drawn), "warning", "surface")
    end

    context:hit({ type = "detail_back" }, { x = r.x + 1, y = r.y + 1, w = r.w - 2, h = r.h - 2 })
end
--- 绘制等级总览或单级机器详情。
function Status:render(context)
    local p = context.painter
    local r = self.rect

    if context.ui.detailLevel then
        detail(self, context)
        return
    end

    p:panel(r)
    local cycleLayout = Status.layoutCycle(r, function(text) return p:measure(text) end)
    p:text(r.x + 2, cycleLayout.titleY, cycleLayout.title, "accent", "surface",
        p:measure(cycleLayout.title) + 1)
    if cycleLayout.hintShown then
        p:textRight(r.x, cycleLayout.titleY, r.w - 3, cycleLayout.hint, "muted", "surface")
    end
    if cycleLayout.barW >= 8 then
        p:text(cycleLayout.labelX, cycleLayout.titleY, cycleLayout.label, "muted", "surface")
    end

    local top = r.y + 2
    local bottom = r.y + r.h - 2
    local available = math.max(0, bottom - top + 1)
    local rowH = available >= 16 and 2 or 1
    local inner = { x = r.x + 2, w = math.max(1, r.w - 4) }
    local cols = columns(inner, { 0.30, 0.24, 0.46 })
    local parallelLabel = "并行 "
    local parallelLabelW = p:measure(parallelLabel)
    local parallelIdealW = parallelLabelW + 7 + 1 + 7
    local parallelW = math.min(parallelIdealW, cols[3].w)
    local parallelValueSpace = math.max(2, parallelW - parallelLabelW - 1)
    local parallelLeftW = math.max(1, math.floor(parallelValueSpace / 2))
    local parallelRightW = math.max(1, parallelValueSpace - parallelLeftW)
    local rightEdge = cols[3].x + cols[3].w
    local rightX = rightEdge - parallelW
    local levelBarX = inner.x
    local levelBarW = math.max(0, rightX - levelBarX - 1)

    for level = 1, 8 do
        local row = self.props.levels[level]
        local y = top + (level - 1) * rowH
        if not row or y > bottom then break end
        context:hit({ type = "detail_level", level = level },
            { x = r.x + 1, y = y, w = r.w - 2, h = rowH })

        local name = row.label .. " " .. tostring(row.deployText or "-")
        p:text(cols[1].x, y, name, row.running and "text" or "disabled", "surface", cols[1].w)
        local markRole = row.rule and row.rule.enabled and "success" or "disabled"
        local mark = tostring(row.mark or "[ ]")
        local markW = p:measure(mark)
        p:text(cols[2].x, y, mark, markRole, "surface")
        p:text(cols[2].x + markW + 1, y, row.switchText, row.switchRole or "muted",
            "surface", math.max(1, cols[2].w - markW - 1))

        local waterRoom = math.max(1, rightX - cols[3].x - 1)
        local waterText = "水量 " .. tostring(row.waterOfText or "- / -")
        if p:measure(waterText) > waterRoom then
            waterText = tostring(row.waterOfText or "- / -")
        end
        p:text(cols[3].x, y, p:truncate(waterText, waterRoom), "text", "surface", waterRoom)

        local successLabel = "成功率"
        local successValue = tostring(row.successText or "-")
        local successRoom = math.max(1, parallelW - p:measure(successLabel) - 1)
        p:text(rightX, y, successLabel, "accent", "surface")
        p:textRight(rightX, y, parallelW, p:truncate(successValue, successRoom),
            "accent", "surface")

        if rowH == 2 then
            if levelBarW > 0 then
                p:bar({ x = levelBarX, y = y + 1, w = levelBarW, h = 1 }, row.ratio or 0)
            end
            local leftX = rightX + parallelLabelW
            local slashX = leftX + parallelLeftW
            local suggestX = slashX + 1
            p:text(rightX, y + 1, parallelLabel, "accent", "surface")
            p:text(leftX, y + 1,
                p:truncate(tostring(row.sampleText or "-"), parallelLeftW),
                row.sampleRole or "text", "surface", parallelLeftW)
            p:text(slashX, y + 1, "/", "muted", "surface")
            p:textRight(suggestX, y + 1, parallelRightW,
                p:truncate(tostring(row.suggestText or "-"), parallelRightW),
                row.suggestRole or "text", "surface")
        end
    end
end

return Status
