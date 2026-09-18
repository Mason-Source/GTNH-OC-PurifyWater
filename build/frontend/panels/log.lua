local unicode = require("unicode")
local fstate  = require("frontend.state")
local theme   = require("frontend.theme")
local widgets = require("frontend.widgets")
local logs    = require("shared.logs")
local log     = {}
function log.draw(data)
    local area       = fstate.areas.log
    local rows       = widgets.textAreaRows(area, 1)
    local maxW       = area.w - 3
    local title      = string.format(" 系统日志（%s）点这里切换 ", logs.getLevel())
    fstate.logTitle  = { x = area.x + 1, y = area.y + 1, w = unicode.wlen(title), h = 1 }
    local frameDirty = fstate.subDirty("log", "frame", table.concat({ area.x, area.y, area.w, area.h,
        tostring(data.system.priority), logs.getLevel() }, ":"))
    if frameDirty then
        widgets.clearArea(area.x, area.y, area.w, area.h)
        widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(data.system.priority == "high"))
        widgets.drawText(area.x + 2, area.y + 1, title,
            logs.isDebug() and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT_CYAN)
    end
    local bodyDirty = fstate.subDirty("log", "body",
        logs.fingerprint() .. "\x1f" .. rows.top .. ":" .. rows.rows .. ":" .. maxW)
    if not (frameDirty or bodyDirty) then return end
    local lines = {}
    local all   = data.logs or {}
    for i = #all, 1, -1 do
        local raw     = tostring(all[i])
        local color   = theme.logColor(logs.kindOf(raw))
        local wrapped = widgets.wrapText(raw, maxW)
        for j = #wrapped, 1, -1 do
            table.insert(lines, 1, { text = wrapped[j], color = color })
        end
        if #lines >= rows.rows then break end
    end
    widgets.clearArea(area.x + 1, rows.top, area.w - 2, rows.rows)
    local start = math.max(1, #lines - rows.rows + 1)
    local y = rows.top
    for i = start, #lines do
        widgets.drawText(area.x + 1, y, lines[i].text, lines[i].color)
        y = y + 1
    end
end
function log.fingerprint(data)
    local area = fstate.areas.log
    local all  = data.logs or {}
    return table.concat({ tostring(data.system.priority), logs.fingerprint(),
        tostring(all[#all] or ""),
        tostring(area and area.h or 0), tostring(area and area.w or 0) }, "\x1f")
end
return log
