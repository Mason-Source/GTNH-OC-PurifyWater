--------------------------------------------------------------------------------
-- frontend/panels/control.lua
--------------------------------------------------------------------------------
-- 【职责】控制面板：6 行状态信息（左列）+ 5 个按钮（拉长、居中）
-- 【不做什么】不判断能不能点 —— 禁用形态由数据决定，热区登记与否只在这里一处决定
-- 【依赖】frontend/{state,theme,widgets,layout}、unicode
-- 【被谁用】frontend/render
--
-- 【六行】系统状态 / 净水主机 / 运行模式 / 功率概况（当前/总）/ ME 接口 / 部署机器（T1-T8）。
-- 【字号无关】列位由 layout.cols 按权重切，换分辨率不会错位。
--------------------------------------------------------------------------------

local unicode   = require("unicode")

local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")
local viewmodel = require("frontend.viewmodel")

local control   = {}

--- 六行信息（数组顺序 = 显示顺序；optional = 面板矮时先丢它）
-- @param data table
-- @return table
local function infoRows(data)
    return {
        { "系统状态：", data.systemText, data.systemColor },
        { "净水主机：", data.hostText, data.hostColor },
        { "运行模式：", data.system.priority == "high" and "高级水优先" or "低级水优先",
            data.system.priority == "high" and theme.COLORS.TEXT_RED or theme.COLORS.TEXT_CYAN, true },
        { "功率概况：", data.powerText, theme.COLORS.TEXT_CYAN },
        { "ME接口：", data.meText, data.meColor, true },
        { "部署机器：", data.machineText, theme.COLORS.TEXT_CYAN }
    }
end

function control.draw(data)
    local area = fstate.areas.control
    widgets.clearArea(area.x, area.y, area.w, area.h)
    widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(data.system.priority == "high"))
    widgets.drawText(area.x + 2, area.y + 1, "控制面板", theme.COLORS.TEXT_CYAN)

    -- 正文可用行：标题下一行 → 底边框上一行
    -- 【按钮占几行】单列 step=2 时 5 个按钮 = (5-1)×2+1 = 9 行；两列 step=1 时 = 3 行
    local avail    = math.max(1, area.h - 3)
    local twoCol   = false
    local rowsUsed = 5
    local blockH   = (rowsUsed - 1) * 2 + 1
    if avail - blockH < 3 then
        twoCol   = true -- 太矮：按钮两列并排（step=1），省下行数给信息
        rowsUsed = 3
        blockH   = rowsUsed
    end
    local infoMax = math.max(1, avail - blockH)

    -- 信息行超长时先丢 optional 的（从后往前），保证"系统状态/主机/功率/机器数"永远在
    local rows    = infoRows(data)
    while #rows > infoMax do
        local dropped = false
        for index = #rows, 1, -1 do
            if rows[index].optional then
                table.remove(rows, index)
                dropped = true
                break
            end
        end
        if not dropped then table.remove(rows) end
    end

    local cols = layout.cols({ x = area.x + 2, w = area.w - 4 }, { 0.34, 0.66 })
    for index, row in ipairs(rows) do
        local y     = area.y + 1 + index
        local value = tostring(row[2])
        if unicode.wlen(value) > cols[2].w - 1 then
            value = unicode.sub(value, 1, math.max(1, cols[2].w - 2)) .. "…"
        end
        widgets.drawText(cols[1].x, y, row[1], theme.COLORS.TEXT)
        widgets.drawText(cols[2].x, y, value, row[3])
    end

    control.drawButtons(area, data, twoCol)
end

--- 画按钮并登记热区（disabled 时不登记 = 点了真的没反应）
-- 【自下而上排】按钮块贴在面板底部，中间剩下多少就给信息行
-- @param area table
-- @param data table
-- @param twoCol boolean|nil 两列并排（面板太矮时）
function control.drawButtons(area, data, twoCol)
    fstate.buttons = {}

    -- 启动按钮能不能点：判据只有一处（viewmodel.startBlockedReason），键盘 X 用同一处，
    --   免得出现"按钮灰着、按 X 却能发命令"。运行中它返回 nil（那是「停机」，任何情况都允许）。
    local blocked  = viewmodel.startBlockedReason(data)
    local locked   = blocked ~= nil
    local items    = {
        {
            name     = "system",
            action   = "system_toggle",
            label    = data.system.running and "停机" or "启动系统",
            color    = data.system.running and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT,
            bg       = data.system.running and theme.COLORS.BTN_BG_HOVER or theme.COLORS.BTN_BG,
            disabled = locked and not data.system.running
        },
        {
            name   = "priority",
            action = "priority_toggle",
            label  = data.system.priority == "high" and "切到低级水优先" or "切到高级水优先",
            color  = theme.COLORS.TEXT,
            bg     = data.system.priority == "high" and theme.COLORS.BTN_PRIORITY_HIGH
                or theme.COLORS.BTN_BG
        },
        {
            name = "refresh",
            action = "refresh",
            label = "刷新扫描",
            color = theme.COLORS.TEXT,
            bg = theme.COLORS.BTN_BG
        },
        {
            name     = "net",
            action   = "net_toggle",
            label    = data.net.enabled and "无线广播：开" or "无线广播：关",
            color    = data.net.enabled and theme.COLORS.TEXT_CYAN or theme.COLORS.TEXT_YELLOW,
            bg       = data.net.enabled and theme.COLORS.BTN_BG_HOVER or theme.COLORS.BTN_BG,
            disabled = not data.net.available
        },
        {
            name = "quit",
            action = "quit",
            label = "退出程序",
            color = theme.COLORS.TEXT_RED,
            bg = theme.COLORS.BTN_BG
        }
    }

    -- 单列：按钮撑满面板宽度（留边）并居中
    local margin   = 3
    local btnW, btnX, step, perRow
    if twoCol then
        perRow = 2
        btnW   = math.floor((area.w - margin * 2 - 1) / 2)
        btnX   = area.x + margin
        step   = 1
    else
        perRow = 1
        btnW   = area.w - margin * 2
        btnX   = area.x + margin
        step   = 2
    end

    local rowsUsed = math.ceil(#items / perRow)
    local startY   = area.y + area.h - 2 - ((rowsUsed - 1) * step + 1) + 1

    local y        = startY
    for index, item in ipairs(items) do
        local slot = (index - 1) % perRow
        if slot == 0 and index > 1 then y = y + step end
        local x = btnX + slot * (btnW + 1)
        if not item.disabled then
            fstate.buttons[item.name] = {
                x = x,
                y = y,
                w = btnW,
                h = 1,
                action = item.action,
                label = item.label
            }
        end
        widgets.drawButton(x, y, btnW, item.label, item.color, item.bg, item.disabled)
    end
end

--- 指纹：六行文案 + 按钮形态（**不看时间**：界面不再显示任何时刻）
function control.fingerprint(data)
    return table.concat({
        tostring(data.systemText), tostring(data.hostText), tostring(data.system.priority),
        tostring(data.powerText), tostring(data.meText), tostring(data.machineText),
        tostring(data.net.enabled), tostring(data.net.available),
        tostring(data.system.locked), tostring(#data.hardware.missing),
        tostring(fstate.areas.control and fstate.areas.control.h or 0)
    }, "\x1f")
end

return control
