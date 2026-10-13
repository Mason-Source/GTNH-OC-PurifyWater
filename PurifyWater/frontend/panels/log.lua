--------------------------------------------------------------------------------
-- frontend/panels/log.lua
--------------------------------------------------------------------------------
-- 【职责】系统日志：把最近几行日志折行后画在面板里（新的在下）
-- 【依赖】frontend/{state,theme,widgets}、shared/logs
-- 【被谁用】frontend/render
--
-- 重绘分两格：框+标题、行区；行数用同一公式算。
-- 不带时间戳：os.time 是游戏内时间，对日志无意义。
--------------------------------------------------------------------------------

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
    local ro         = fstate.readOnly == true
    local title      = ro and " 系统日志（只读） "
        or string.format(" 系统日志（%s）点这里切换 ", logs.getLevel())

    -- 标题即按钮：点击切 user/debug（镜像端不登记）
    if not ro then
        fstate.logTitle  = { x = area.x + 1, y = area.y + 1, w = unicode.wlen(title), h = 1 }
    end

    -- ① 框+标题：几何/边框色/级别变才重画
    local frameDirty = fstate.subDirty("log", "frame", table.concat({ area.x, area.y, area.w, area.h,
        tostring(data.system.priority), logs.getLevel() }, ":"))
    if frameDirty then
        widgets.clearArea(area.x, area.y, area.w, area.h)
        widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(data.system.priority == "high"))
        widgets.drawText(area.x + 2, area.y + 1, title,
            logs.isDebug() and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT_CYAN)
    end

    -- ② 行区：日志内容 + 布局参数，不脏不折行
    -- 【镜像端】本地 logs 缓冲是空的：行区指纹必须以 data.logs 为准
    --   （#all 与首/末行足以发现变化；本地指纹对主端仍然有效）
    local all       = data.logs or {}
    local bodyDirty = fstate.subDirty("log", "body", table.concat({ logs.fingerprint(),
        #all, tostring(all[1] or ""), tostring(all[#all] or ""),
        rows.top, rows.rows, maxW }, "\x1f"))
    if not (frameDirty or bodyDirty) then return end

    -- 从最新往前折到可见行数；颜色按整行判一次并随片段走。
    local lines = {} -- 每项 = { text = 折行片段, color = **按整行判定的颜色** }
    for i = #all, 1, -1 do
        local raw     = tostring(all[i])
        local color   = theme.logColor(logs.kindOf(raw))
        local wrapped = widgets.wrapText(raw, maxW)
        for j = #wrapped, 1, -1 do
            table.insert(lines, 1, { text = wrapped[j], color = color })
        end
        if #lines >= rows.rows then break end
    end

    -- 只清行区，避免整块闪烁
    widgets.clearArea(area.x + 1, rows.top, area.w - 2, rows.rows)
    local start = math.max(1, #lines - rows.rows + 1)
    local y = rows.top
    for i = start, #lines do
        -- 颜色来自 logs.kindOf（按前缀判）
        widgets.drawText(area.x + 1, y, lines[i].text, lines[i].color)
        y = y + 1
    end
end

--- 指纹：logs.fingerprint() + 尺寸 + 边框色依据
-- 级别与宽高都必须进指纹。
function log.fingerprint(data)
    local area = fstate.areas.log
    local all  = data.logs or {}
    return table.concat({ tostring(data.system.priority), logs.fingerprint(),
        tostring(#all), tostring(all[1] or ""), tostring(all[#all] or ""),
        tostring(area and area.h or 0), tostring(area and area.w or 0) }, "\x1f")
end

return log
