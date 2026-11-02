--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/config_table.lua
--
-- 定位：配置页主表格与数字键盘组件。
-- 功能：绘制等级参数、收集/制作状态、全局参数编辑键盘和制作绑定面板。
-- 边界：只发出前端动作；不校验或持久化配置，不执行绑定。
--------------------------------------------------------------------------------

local Component = require("frontend.ui.base")
local config_constants = require("shared.constants")
local util = require("shared.util")
local ConfigTable = {}

--- 创建配置表格与键盘组件。
function ConfigTable.new()
    local self = Component.new("config_table", {})
    self.fingerprint = ConfigTable.fingerprint
    self.render = ConfigTable.render
    return self
end

--- 生成配置内容、编辑状态和绑定面板的渲染指纹。
function ConfigTable:fingerprint(context)
    local parts = {
        self.key, self.rect.x, self.rect.y, self.rect.w, self.rect.h, context.themeId,
        tostring(context.ui.editLevel or 0), tostring(context.ui.editField or ""),
        tostring(context.ui.editBuf or ""),
        tostring(context.ui.producePage or 1),
        tostring(context.ui.produceCandidatePage or 1),
        tostring(self.props.system and self.props.system.t7Boost),
        tostring(self.props.system and self.props.system.t6DualLithium),
        tostring(self.props.system and self.props.system.energyFactor),
        tostring(self.props.net and self.props.net.strength),
    }
    for level = 1, 8 do
        local row = self.props.rows[level] or {}
        parts[#parts + 1] = table.concat({
            row.label, tostring(row.enabled), tostring(row.thresholdK), tostring(row.weight),
            tostring(row.collectText), tostring(row.produceText),
        }, ":")
        local product = (self.props.produce.levels or {})[level] or {}
        parts[#parts + 1] = table.concat({
            tostring(product.state), tostring(product.reason), tostring(product.bound),
            tostring(product.configured), tostring(product.online), tostring(product.count),
            tostring(product.ready), tostring(product.unbound), tostring(product.missing),
        }, ":")
        for _, machine in ipairs(product.machines or {}) do
            parts[#parts + 1] = table.concat({
                tostring(machine.address), tostring(machine.bound), tostring(machine.online),
                tostring(machine.text), tostring(machine.sideState), tostring(machine.transposer),
            }, "~")
        end
    end
    local binding = self.props.produce.binding or {}
    parts[#parts + 1] = table.concat({
        tostring(binding.level), tostring(binding.machine), tostring(binding.loading),
    }, ":")
    for _, address in ipairs(binding.candidates or {}) do parts[#parts + 1] = tostring(address) end
    return table.concat(parts, "\x1f")
end

local function columns(x, width)
    local weights = { 0.12, 0.12, 0.24, 0.16, 0.18, 0.18 }
    local out, total = {}, 0
    for _, weight in ipairs(weights) do total = total + weight end
    local cursor = x
    for index, weight in ipairs(weights) do
        local w = (index == #weights) and (x + width - cursor) or math.floor(width * weight / total)
        out[index] = { x = cursor, w = w }
        cursor = cursor + w
    end
    return out
end

local function isSelected(context, level, field)
    return context.ui.editLevel == level and context.ui.editField == field
end

local function cellText(painter, col, y, text, role, selected, rowSelected, selectedRole)
    local bg = selected and "cellSelected"
        or (rowSelected and "cellSelected" or "surface")
    if bg ~= "surface" then
        painter:fill({ x = col.x, y = y, w = col.w, h = 1 }, bg)
    end
    local fg = selected and (selectedRole or role) or role
    painter:text(col.x, y, text, fg, bg, col.w)
end

local function keyRole(action)
    local kind = type(action) == "table" and action.kind or nil
    if kind == "commit" then return "success" end
    if kind == "cancel" then return "muted" end
    if kind == "copy" or kind == "mul" or kind == "div" then return "warning" end
    if kind == "set" then return "accent" end
    return "text"
end

local function drawKey(context, rect, label, action, active, background)
    local p = context.painter
    p:button(rect, label, active, nil, active and "success" or keyRole(action), background)
    context:hit(action, rect)
end

local DIGIT_ROWS = {
    { "7", "8", "9" },
    { "4", "5", "6" },
    { "1", "2", "3" },
    { nil, "0", nil },
}
local ACTION_ROWS = {
    { { "x2", "mul", 2 }, { "x10", "mul", 10 }, { "x100", "mul", 100 } },
    { { "/2", "div", 2 }, { "/10", "div", 10 }, { "/100", "div", 100 } },
    { { "x1000", "mul", 1000 }, { "/1000", "div", 1000 }, { "←", "back" } },
    { { "C", "clear" }, { "✔", "commit" }, { "✘", "cancel" } },
}
local PRESET_ROWS = {
    { { "1k", "set", "1000" }, { "10k", "set", "10000" }, { "100k", "set", "100000" } },
    { { "1M", "set", "1000000" }, { "10M", "set", "10000000" }, { "100M", "set", "100000000" } },
    { { "1G", "set", "1000000000" }, { "10G", "set", "10000000000" }, { "100G", "set", "100000000000" } },
    { { "1T", "set", "1000000000000" }, { "10T", "set", "10000000000000" }, { "=上级", "copy" } },
}
local WEIGHT_ACTION_ROWS = {
    { { "←", "back" }, { "C", "clear" } },
    { { "✔", "commit" }, { "✘", "cancel" } },
}

local function drawPad(context, x, y, rows, keyW, gap, background)
    local count = 0
    for _, row in ipairs(rows) do count = math.max(count, #row) end
    for rowIndex, row in ipairs(rows) do
        for colIndex = 1, count do
            local value = row[colIndex]
            if value then
                local rect = {
                    x = x + (colIndex - 1) * (keyW + gap),
                    y = y + rowIndex - 1,
                    w = keyW,
                    h = 1,
                }
                local label, kind, arg
                if type(value) == "table" then label, kind, arg = value[1], value[2], value[3]
                else label, kind, arg = value, "digit", value end
                drawKey(context, rect, label, {
                    type = "keypad",
                    kind = kind,
                    value = arg,
                }, false, background)
            end
        end
    end
end

local function hintText(context)
    local field, level = context.ui.editField, context.ui.editLevel
    if field == "threshold" then
        return string.format("正在编辑 %s 阈值：%s_", tostring(level), context.ui.editBuf or "")
    elseif field == "weight" then
        return string.format("正在编辑 %s 权重：%s_", tostring(level), context.ui.editBuf or "")
    elseif field == "factor" then
        return string.format("正在编辑 能源仓利用因子：%s_", context.ui.editBuf or "")
    elseif field == "strength" then
        return string.format("正在编辑 无线范围：%s_", context.ui.editBuf or "")
    elseif field == "boost" then
        return "选择收集方式"
    elseif field == "produce" then
        return "制作自动化"
    end
    return "选择表格中的项目"
end

local function drawThresholdPad(context, x, y, w)
    local keyW = math.max(5, math.min(7, math.floor((w - 8) / 11)))
    local gap = 1
    local padW = 3 * keyW + 2 * gap
    local total = padW * 3 + 4
    local startX = x + math.max(0, math.floor((w - total) / 2))
    drawPad(context, startX, y, DIGIT_ROWS, keyW, gap, "chip")
    drawPad(context, startX + padW + 2, y, ACTION_ROWS, keyW, gap, "chipWarm")
    drawPad(context, startX + (padW + 2) * 2, y, PRESET_ROWS, keyW, gap, "chipCool")
end

local function drawWeightPad(context, x, y, w)
    local keyW = math.max(5, math.min(7, math.floor((w - 14) / 5)))
    local gap = 1
    local digitW = 3 * keyW + 2 * gap
    local actionW = 2 * keyW + gap
    local sep = 3
    local total = digitW + sep + actionW
    local startX = x + math.max(0, math.floor((w - total) / 2))
    drawPad(context, startX, y, DIGIT_ROWS, keyW, gap, "chip")
    drawPad(context, startX + digitW + sep, y + 1, WEIGHT_ACTION_ROWS, keyW, gap, "chipWarm")
end

local function drawOptions(context, x, y, w, options)
    local keyW = 10
    local gap = 2
    local total = #options * keyW + (#options - 1) * gap
    local startX = x + math.max(0, math.floor((w - total) / 2))
    for index, option in ipairs(options) do
        drawKey(context,
            { x = startX + (index - 1) * (keyW + gap), y = y, w = keyW, h = 1 },
            option.label, option.action, option.current)
    end
end

local function drawPage(context, x, y, page, pages, actionType)
    if pages <= 1 then return x end
    local p = context.painter
    local prev = "‹"
    local nextText = "›"
    if page > 1 then
        local rect = { x = x, y = y, w = 1, h = 1 }
        p:button(rect, prev, false)
        context:hit({ type = actionType, delta = -1 }, rect)
    end
    x = x + 2
    local label = string.format("%d/%d", page, pages)
    p:text(x, y, label, "muted", "surface")
    x = x + p:measure(label) + 1
    if page < pages then
        local rect = { x = x, y = y, w = 1, h = 1 }
        p:button(rect, nextText, false)
        context:hit({ type = actionType, delta = 1 }, rect)
    end
    return x + 1
end

local function sideText(machine)
    if machine.configured then return "配置就绪", "success" end
    if machine.sideState == "未绑定" then return "-", "disabled" end
    return tostring(machine.sideState or "自动配置中"), "warning"
end

local function produceColumns(area)
    local innerX, innerW = area.x + 2, math.max(1, area.w - 4)
    local numW, coordW, transW, sideW, actW, gap = 4, 20, 14, 18, 8, 2
    local blockW = math.min(innerW, numW + coordW + transW + sideW + actW + gap * 4)
    local x = innerX + math.max(0, math.floor((innerW - blockW) / 2))
    return {
        num = { x = x, w = numW },
        coord = { x = x + numW + gap, w = coordW },
        trans = { x = x + numW + coordW + gap * 2, w = transW },
        side = { x = x + numW + coordW + transW + gap * 3, w = sideW },
        act = { x = x + numW + coordW + transW + sideW + gap * 4, w = actW },
    }
end

local drawCandidatePanel

local function drawProducePanel(self, context, top, height)
    local p = context.painter
    local r = self.rect
    local level = context.ui.editLevel or 1
    local product = (self.props.produce.levels or {})[level] or {}
    local machines = product.machines or {}
    local binding = self.props.produce.binding or {}
    if binding.level == level and binding.machine then
        drawCandidatePanel(self, context, top, height)
        return
    end

    local perPage = math.max(1, height - 2)
    local pages = math.max(1, math.ceil(#machines / perPage))
    local page = math.min(math.max(1, tonumber(context.ui.producePage) or 1), pages)
    local configured = 0
    for _, machine in ipairs(machines) do
        if machine.configured then configured = configured + 1 end
    end

    local y = top
    local x = r.x + 2
    local title = "制作自动化 · " .. config_constants.levelLabel(level)
    p:text(x, y, title, "accent", "surface", 22)
    x = x + p:measure(title) + 2
    p:text(x, y, string.format("%d/%d 就绪", configured, #machines), "text", "surface", 12)
    x = x + p:measure(string.format("%d/%d 就绪", configured, #machines)) + 2
    x = drawPage(context, x, y, page, pages, "produce_page")
    if product.reason then
        local room = r.x + r.w - 28 - x
        if room >= 8 then
            p:text(x, y, product.reason, "warning", "surface", room)
        end
    end

    local toggle = { x = r.x + r.w - 12, y = y, w = 10, h = 1 }
    local canToggle = product.ready == true or product.enabled == true
    p:button(toggle, product.enabled and "[关]" or "[开]",
        product.enabled == true, not canToggle)
    if canToggle then
        context:hit({ type = "command", name = "produce_toggle", level = level,
            value = product.enabled ~= true }, toggle)
    end

    local cols = produceColumns(r)
    local hy = y + 1
    p:text(cols.num.x, hy, "#", "muted", "surface", cols.num.w)
    p:text(cols.coord.x, hy, "坐标", "muted", "surface", cols.coord.w)
    p:text(cols.trans.x, hy, "转运器", "muted", "surface", cols.trans.w)
    p:text(cols.side.x, hy, "侧位", "muted", "surface", cols.side.w)
    p:text(cols.act.x, hy, "操作", "muted", "surface", cols.act.w)

    local first = (page - 1) * perPage + 1
    for index = 1, perPage do
        local machine = machines[first + index - 1]
        local ry = hy + index
        if not machine then break end
        local rowRole = machine.online == false and "disabled" or "text"
        p:text(cols.num.x, ry, tostring(first + index - 1), "muted", "surface", cols.num.w)
        p:text(cols.coord.x, ry, machine.text or "-", rowRole, "surface", cols.coord.w)
        local transposer = machine.bound and util.shortAddress(machine.transposer) or "未绑定"
        p:text(cols.trans.x, ry, transposer,
            machine.bound and rowRole or "disabled", "surface", cols.trans.w)
        local side, sideRole = sideText(machine)
        p:text(cols.side.x, ry, side, sideRole, "surface", cols.side.w)
        local key = { x = cols.act.x, y = ry, w = 6, h = 1 }
        p:button(key, "[选择]", false, machine.online == false)
        if machine.online ~= false then
            context:hit({ type = "command", name = "produce_bind_begin",
                level = level, machine = machine.address }, key)
        end
    end

    if #machines == 0 then
        p:text(r.x + 4, hy + 1, "暂无机器数据", "muted", "surface", r.w - 8)
    end
end

drawCandidatePanel = function(self, context, top, height)
    local p = context.painter
    local r = self.rect
    local binding = self.props.produce.binding or {}
    local level = context.ui.editLevel or binding.level or 1
    local product = (self.props.produce.levels or {})[level] or {}
    local machine
    for _, item in ipairs(product.machines or {}) do
        if item.address == binding.machine then machine = item; break end
    end

    local y = top
    local title = "选择转运器 · " .. config_constants.levelLabel(level)
    p:text(r.x + 2, y, title, "accent", "surface", 24)
    local emptyRect = { x = r.x + r.w - 23, y = y, w = 11, h = 1 }
    local cancelRect = { x = r.x + r.w - 11, y = y, w = 9, h = 1 }
    p:button(emptyRect, "[空=解绑]", false, binding.loading == true)
    p:button(cancelRect, "[取消]", false)
    if binding.loading ~= true then
        context:hit({ type = "command", name = "produce_bind_select",
            machine = binding.machine, address = "" }, emptyRect)
    end
    context:hit({ type = "command", name = "produce_bind_cancel" }, cancelRect)

    local candidates = binding.candidates or {}
    local perPage = math.max(1, height - 3)
    local pages = math.max(1, math.ceil(#candidates / perPage))
    local page = math.min(math.max(1, tonumber(context.ui.produceCandidatePage) or 1), pages)
    local machineText = machine and machine.text or util.shortAddress(binding.machine)
    local info = string.format("机器 %s · 未绑定 %d 个", machineText, #candidates)
    p:text(r.x + 2, y + 1, info, "text", "surface", 38)
    drawPage(context, r.x + 42, y + 1, page, pages, "produce_candidate_page")

    if binding.loading then
        p:text(r.x + 4, y + 3, "正在扫描网络中的未绑定转运器…", "warning", "surface", r.w - 8)
        return
    end
    if #candidates == 0 then
        p:text(r.x + 4, y + 3, "没有可选的未绑定转运器；可选择空以解除当前绑定", "muted", "surface", r.w - 8)
        return
    end

    local cols = produceColumns(r)
    p:text(cols.num.x, y + 2, "#", "muted", "surface", cols.num.w)
    p:text(cols.trans.x, y + 2, "转运器（短地址）", "muted", "surface", cols.trans.w + cols.coord.w)
    p:text(cols.act.x, y + 2, "操作", "muted", "surface", cols.act.w)

    local first = (page - 1) * perPage + 1
    for index = 1, perPage do
        local address = candidates[first + index - 1]
        local ry = y + 3 + index - 1
        if not address then break end
        p:text(cols.num.x, ry, tostring(first + index - 1), "muted", "surface", cols.num.w)
        p:text(cols.trans.x, ry, util.shortAddress(address), "text", "surface", cols.trans.w + cols.coord.w)
        local key = { x = cols.act.x, y = ry, w = 6, h = 1 }
        p:button(key, "[选择]", false)
        context:hit({ type = "command", name = "produce_bind_select",
            machine = binding.machine, address = address }, key)
    end
end

local function drawKeyboard(self, context, top, height)
    local p = context.painter
    local r = self.rect
    local w = r.w - 4
    local field = context.ui.editField

    if field == "produce" then
        drawProducePanel(self, context, top, height)
        return
    end

    local y = top + 1
    p:text(r.x + 2, top, hintText(context), "warning", "surface", w)

    if field == "threshold" then
        drawThresholdPad(context, r.x + 2, y, w)
    elseif field == "weight" or field == "factor" or field == "strength" then
        drawWeightPad(context, r.x + 2, y, w)
    elseif field == "boost" then
        local level = context.ui.editLevel
        local options
        if level == 1 or level == 2 then
            local on = (self.props.system.reflux or {})[level] == true
            options = {
                { label = "开", current = on, action = { type = "option", name = "reflux_set", level = level, value = true } },
                { label = "关", current = not on, action = { type = "option", name = "reflux_set", level = level, value = false } },
            }
        elseif level == config_constants.T6_LEVEL then
            local on = self.props.system.t6DualLithium == true
            options = {
                { label = "标准", current = not on, action = { type = "option", name = "t6_dual_lithium_set", value = false } },
                { label = "双锂", current = on, action = { type = "option", name = "t6_dual_lithium_set", value = true } },
            }
        else
            options = {}
            for _, value in ipairs(config_constants.T7_BOOST_OPTIONS) do
                options[#options + 1] = {
                    label = "×" .. tostring(value),
                    current = value == self.props.system.t7Boost,
                    action = { type = "option", name = "t7_boost_set", value = value },
                }
            end
        end
        drawOptions(context, r.x + 2, y + 1, w, options)
    end
end
--- 绘制配置表格、数字键盘或制作绑定面板。
function ConfigTable:render(context)
    local p = context.painter
    local r = self.rect
    local system = self.props.system or {}
    p:panel(r, "调度配置")
    if r.h < 10 then return end

    local cols = columns(r.x + 2, r.w - 4)
    local heads = { "级", "勾选", "阈值 kL", "权重", "收集", "制作" }
    p:text(r.x + 2, r.y + 3, string.rep("─", r.w - 4), "chartAxis", "surface", r.w - 4)
    for index, head in ipairs(heads) do
        p:text(cols[index].x, r.y + 4, head, "muted", "surface", cols[index].w)
    end
    p:text(r.x + 2, r.y + 5, string.rep("─", r.w - 4), "chartAxis", "surface", r.w - 4)

    local factorText = "利用因子 " .. tostring(system.energyFactor or 100) .. "%"
    local strengthText = "无线范围 " .. tostring((self.props.net or {}).strength or 0)
    local strengthSelected = context.ui.editField == "strength"
    local factorSelected = context.ui.editField == "factor"
    local factorW = p:measure(factorText)
    local strengthW = p:measure(strengthText)
    local factorX = r.x + r.w - factorW - 2
    local strengthX = factorX - strengthW - 2
    p:text(strengthX, r.y + 2, strengthText, strengthSelected and "warning" or "accent", "surface", strengthW)
    p:text(factorX, r.y + 2, factorText, factorSelected and "warning" or "accent", "surface", factorW)
    context:hit({ type = "select_global", field = "strength" },
        { x = strengthX, y = r.y + 2, w = strengthW, h = 1 })
    context:hit({ type = "select_global", field = "factor" },
        { x = factorX, y = r.y + 2, w = factorW, h = 1 })

    local keypadH = math.min(9, math.max(3, r.h - 16))
    local keyTop = r.y + r.h - 1 - keypadH
    local count = math.max(0, math.min(8, keyTop - 3 - (r.y + 5)))
    for level = 1, count do
        local row = self.props.rows[level]
        local y = r.y + 5 + level
        local rowSelected = context.ui.editLevel == level
        if row then
            cellText(p, cols[1], y, row.label, "accent", false, rowSelected)
            cellText(p, cols[2], y, row.enabled and "[√]" or "[ ]",
                row.enabled and "success" or "disabled", false)
            cellText(p, cols[3], y, row.thresholdText, "text",
                isSelected(context, level, "threshold"), false, "warning")
            cellText(p, cols[4], y, row.weightText, "text",
                isSelected(context, level, "weight"), false, "warning")
            cellText(p, cols[5], y, row.collectText, "text",
                isSelected(context, level, "boost"), false, "warning")
            cellText(p, cols[6], y, row.produceText,
                row.produceRole or (row.produceEnabled and "success" or "disabled"),
                isSelected(context, level, "produce"))

            context:hit({ type = "command", name = "level_enabled_toggle", level = level },
                { x = cols[2].x, y = y, w = cols[2].w, h = 1 })
            context:hit({ type = "select_cell", level = level, field = "threshold" },
                { x = cols[3].x, y = y, w = cols[3].w, h = 1 })
            context:hit({ type = "select_cell", level = level, field = "weight" },
                { x = cols[4].x, y = y, w = cols[4].w, h = 1 })
            if level == 1 or level == 2 or level == config_constants.T6_LEVEL
                or level == config_constants.T7_LEVEL then
                context:hit({ type = "select_cell", level = level, field = "boost" },
                    { x = cols[5].x, y = y, w = cols[5].w, h = 1 })
            end
            if row.produceClickable then
                context:hit({ type = "select_cell", level = level, field = "produce" },
                    { x = cols[6].x, y = y, w = cols[6].w, h = 1 })
            end
        end
    end

    p:text(r.x + 2, keyTop - 2, string.rep("─", r.w - 4), "chartAxis", "surface", r.w - 4)
    drawKeyboard(self, context, keyTop, keypadH)
end

return ConfigTable
