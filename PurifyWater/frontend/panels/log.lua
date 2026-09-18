--------------------------------------------------------------------------------
-- frontend/panels/log.lua
--------------------------------------------------------------------------------
-- 【职责】系统日志：把最近几行日志折行后画在面板里（新的在下）
-- 【依赖】frontend/{state,theme,widgets}、shared/logs
-- 【被谁用】frontend/render
--
-- 【重绘粒度】分两格：框+标题（只在几何/级别变时画）与行区（只在日志真的变了才画）。
--   日志一行行冒出来时框与标题纹丝不动 —— 整块清底重画就是屏幕上那种闪。
-- 【行数】可见行数由 widgets.textAreaRows(area, 1) 算，与画的时候同一个公式：
--   v2 曾出现"缓冲比画面多一行 -> 最新一行永远看不见"。
-- 【不带时间戳】行首没有 [hh:mm:ss]：os.time 是游戏内时间，对日志没有意义。
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
    local title      = string.format(" 系统日志（%s）点这里切换 ", logs.getLevel())

    -- 标题就是按钮：点一下切 user / debug（想看排错细节时不用重跑程序）
    fstate.logTitle  = { x = area.x + 1, y = area.y + 1, w = unicode.wlen(title), h = 1 }

    -- ① 框 + 标题：几何 / 边框色 / 级别变了才重画
    local frameDirty = fstate.subDirty("log", "frame", table.concat({ area.x, area.y, area.w, area.h,
        tostring(data.system.priority), logs.getLevel() }, ":"))
    if frameDirty then
        widgets.clearArea(area.x, area.y, area.w, area.h)
        widgets.drawBorder(area.x, area.y, area.w, area.h, theme.borderColor(data.system.priority == "high"))
        widgets.drawText(area.x + 2, area.y + 1, title,
            logs.isDebug() and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT_CYAN)
    end

    -- ② 行区：指纹用 logs.fingerprint()（含"累计写入数"，新行必变）+ 布局参数
    --   —— 不必为了判脏先把几十行折一遍（不脏就啥都不做）
    local bodyDirty = fstate.subDirty("log", "body",
        logs.fingerprint() .. "\x1f" .. rows.top .. ":" .. rows.rows .. ":" .. maxW)
    if not (frameDirty or bodyDirty) then return end

    -- 从最新往前折行，直到填满可见行数（保证最新那行一定看得见）。
    -- 颜色在折行**之前**判一次、跟着所有片段走：续行没有前缀，逐片段判色会退回默认白
    --   （表现：只有第一行有色，折出来的续行又变白）。
    local lines = {} -- 每项 = { text = 折行片段, color = **按整行判定的颜色** }
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

    -- 只清行区（边框与标题不在里面）：整块清底重画就是屏幕上那种闪
    widgets.clearArea(area.x + 1, rows.top, area.w - 2, rows.rows)
    local start = math.max(1, #lines - rows.rows + 1)
    local y = rows.top
    for i = start, #lines do
        -- 颜色来自 logs.kindOf（按前缀判），不做 find("失败") 这类关键字猜测
        widgets.drawText(area.x + 1, y, lines[i].text, lines[i].color)
        y = y + 1
    end
end

--- 指纹（**面板级开关**）：logs.fingerprint()（条数/累计/末行/级别）+ 面板尺寸 + 边框色依据
-- 级别必须进指纹：切 user/debug 会清空缓冲、整套内容都换掉。
-- 宽高都要：行区子指纹里有 maxW（随宽变），面板级指纹漏了宽就等于那一格永远不评估。
function log.fingerprint(data)
    local area = fstate.areas.log
    local all  = data.logs or {}
    return table.concat({ tostring(data.system.priority), logs.fingerprint(),
        tostring(all[#all] or ""),
        tostring(area and area.h or 0), tostring(area and area.w or 0) }, "\x1f")
end

return log
