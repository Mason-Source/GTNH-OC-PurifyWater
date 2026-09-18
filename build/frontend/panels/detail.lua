local unicode   = require("unicode")
local constants = require("shared.constants")
local utils     = require("shared.utils")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")
local detail    = {}
local BULLET    = "· "
local RULE      = "─"
local function ruleLine(x, y, w, text)
    local head = (text ~= "") and (" " .. text .. " ") or ""
    widgets.drawText(x, y, RULE .. head .. string.rep(RULE, math.max(0, w - unicode.wlen(head) - 1)),
        theme.COLORS.TEXT_DISABLED)
end
local function machineRows(machines, record)
    local num                      = utils.formatNumber
    local list, curW, realW, rateW = {}, 0, 0, 0
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
local function lines(row, level)
    local per      = constants.POWER_LEVELS[level] or 0
    local deployed = row.deployed or 0
    local suggest  = row.suggest or 0
    local running  = (row.active or 0) > 0
    local num      = utils.formatNumber
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
    sep("当前功耗")
    local perPower = row.sample and (row.sample * per) or nil
    item("当前等级总功耗", perPower and (num(perPower * deployed) .. " EU/t" .. stale) or "-", liveWatt)
    sep("每台机器")
    for _, machineRow in ipairs(machineRows(row.machines, row.parallel)) do
        out[#out + 1] = { "item", machineRow[1], machineRow[2], machineRow[3] }
    end
    return out
end
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
    widgets.drawText(area.x + 2, area.y + 1,
        string.format("净水单元详情 · %s", row.label), theme.COLORS.TEXT_CYAN)
    widgets.drawTextRight(area.x + 2, area.w - 4, area.y + 1, "← 点任意处返回", theme.COLORS.TEXT_DISABLED)
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
    if drawn < #rows and top + drawn <= last then
        widgets.drawText(cols[1].x, top + drawn,
            string.format("…（屏高不够，还有 %d 行）", #rows - drawn), theme.COLORS.TEXT_YELLOW)
    end
end
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
