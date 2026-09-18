--------------------------------------------------------------------------------
-- frontend/layout.lua
--------------------------------------------------------------------------------
-- 【职责】先定**网格**（几行几列、每格坐标），再由网格派生出各面板矩形写进 `fstate.areas`
-- 【不做什么】不画东西、不取数据
-- 【依赖】frontend/{state,widgets}、shared/logs
-- 【被谁用】frontend/render（boot 与分辨率变化时各调一次）；面板用 layout.cols 做列对齐
--
-- 【版面】无顶部标题栏，左右两列：
--   ┌ 页签栏：总览 配置 ·········································┐ y=1
--   ├────────────────┬──────────────────────────────────────────┤
--   │ 控制面板        │ 各级净水状态（8 级 × 2 行）                │
--   │ 状态 + 6 行信息 │                                          │
--   │ + 5 个按钮      │                                          │
--   ├────────────────┼──────────────────────────────────────────┤
--   │ 系统日志        │ 水量监视（全部=近1日柱状 / Tn=近2日曲线）  │
--   └────────────────┴──────────────────────────────────────────┘
--   配置页：一块占满内容区的 config 面板（三段表 + 常驻虚拟键盘）。
--
-- 【网格的意义】旧版面板内部到处手算 x 偏移（+38、+72、+115 之类），改一列要重排一片；
--   现在列位只由 `layout.cols()` 按权重切一次，谁都在网格线上。
--------------------------------------------------------------------------------

local fstate         = require("frontend.state")
local widgets        = require("frontend.widgets")
local logs           = require("shared.logs")

local layout         = {}

-- 网格常量（改版面只动这里）
layout.TAB_H         = 1  -- 页签栏
layout.CONTROL_H     = 18 -- 控制面板完整高度（2 边框 + 1 标题 + 6 行信息 + 9 行按钮）
layout.MIN_CONTROL_H = 11 -- 压缩时下限（按钮自动并排）
layout.MIN_LOG_H     = 6
layout.STATUS_TWO_H  = 19 -- 净水状态：每级 2 行（信息 + 进度条）；运行周期条已挤进标题行，故 19
layout.STATUS_ONE_H  = 12 -- 装不下时每级 1 行
-- 【配置页拆成三块】各块**按内容定高**、从上往下贴紧排（敲键时列表与键盘本体都不动）：
--   ① 列表：边框 2 + 标题 1 + 表头 1 + 8 行 = 12
--   ② 回显：1 行（"正在改 T3…"），**只有它随敲键重画**
--   ③ 键盘：空 1 + 键盘 4 = 5（无边框，省一行也省一次重画）
layout.CONFIG_LIST_H = 12
layout.EDITLINE_H    = 1
layout.KEYPAD_H      = 5
layout.MIN_CHART_H   = 10 -- 水量监视最小高度（标题 + 画布 + 刻度）
layout.SIDE_PAD      = 1  -- 左右页边距
layout.COL_GAP       = 1  -- 两列之间的空隙

--- 按权重把一块矩形横向切成若干列（面板内部对齐用）
-- @param area table { x = , w = }
-- @param weights table 权重数组，例如 { 0.6, 0.4 }
-- @return table { { x = , w = }, ... }
function layout.cols(area, weights)
    local out, total = {}, 0
    for _, weight in ipairs(weights) do total = total + weight end
    if total <= 0 then total = 1 end

    local x, left = area.x, area.w
    for index, weight in ipairs(weights) do
        local w
        if index == #weights then
            w = left
        else
            w = math.floor(area.w * weight / total)
            left = left - w
        end
        out[index] = { x = x, w = w }
        x = x + w
    end
    return out
end

--- 计算布局（分辨率变化后必须重新调用）
function layout.calculate()
    fstate.W, fstate.H = fstate.gpu.getResolution()

    local W, H         = fstate.W, fstate.H

    -- ① 网格：行（页签栏 + 内容区）
    local grid         = { rows = {}, cols = {} }
    grid.rows.top      = { y = 1, h = layout.TAB_H }
    grid.rows.body     = { y = layout.TAB_H + 1, h = H - layout.TAB_H }

    -- ② 网格：列（左窄右宽；左列夹在合理区间，免得极窄/极宽屏失衡）
    local leftW        = math.floor(W * 0.30)
    leftW              = math.max(26, math.min(leftW, 46, W - 40))
    local rightW       = W - leftW - layout.SIDE_PAD * 2 - layout.COL_GAP
    grid.cols.left     = { x = 1 + layout.SIDE_PAD, w = leftW }
    grid.cols.right    = { x = 1 + layout.SIDE_PAD + leftW + layout.COL_GAP, w = rightW }
    fstate.grid        = grid

    local bodyY        = grid.rows.body.y
    local bodyH        = grid.rows.body.h

    -- ③ 右列：净水状态（内容定高）→ 水量监视（吃剩余）
    local statusH      = (bodyH >= layout.STATUS_TWO_H + layout.MIN_CHART_H + 1)
        and layout.STATUS_TWO_H or layout.STATUS_ONE_H
    local chartH       = bodyH - statusH - 1
    if chartH < layout.MIN_CHART_H then
        chartH  = math.min(layout.MIN_CHART_H, bodyH)
        statusH = math.max(6, bodyH - chartH - 1)
    end

    -- ④ 左列：控制面板（内容定高）→ 系统日志（吃剩余）
    local controlH = math.min(layout.CONTROL_H, bodyH - layout.MIN_LOG_H - 1)
    controlH       = math.max(math.min(layout.MIN_CONTROL_H, bodyH), controlH)
    local logH     = bodyH - controlH - 1
    if logH < layout.MIN_LOG_H then
        logH     = math.min(layout.MIN_LOG_H, bodyH)
        controlH = math.max(6, bodyH - logH - 1)
    end

    -- ⑤ 面板矩形
    fstate.areas.tabBar   = { x = 1, y = grid.rows.top.y, w = W, h = layout.TAB_H }
    fstate.areas.control  = { x = grid.cols.left.x, y = bodyY, w = grid.cols.left.w, h = controlH }
    fstate.areas.log      = {
        x = grid.cols.left.x,
        y = bodyY + controlH + 1,
        w = grid.cols.left.w,
        h = logH
    }
    fstate.areas.status   = { x = grid.cols.right.x, y = bodyY, w = grid.cols.right.w, h = statusH }
    fstate.areas.chart    = {
        x = grid.cols.right.x,
        y = bodyY + statusH + 1,
        w = grid.cols.right.w,
        h = chartH
    }
    -- 配置页：三块各自按内容定高、从上往下贴紧排（不再是"列表在顶、键盘贴底"的一大片空白）
    local configX         = 1 + layout.SIDE_PAD
    local configW         = W - layout.SIDE_PAD * 2
    local configH         = math.min(layout.CONFIG_LIST_H, bodyH)
    local editH           = math.min(layout.EDITLINE_H, math.max(0, bodyH - configH))
    local keypadH         = math.min(layout.KEYPAD_H, math.max(0, bodyH - configH - editH))
    fstate.areas.config   = { x = configX, y = bodyY, w = configW, h = configH }
    fstate.areas.editline = { x = configX, y = bodyY + configH, w = configW, h = editH }
    fstate.areas.keypad   = { x = configX, y = bodyY + configH + editH, w = configW, h = keypadH }

    -- 缓冲上限与"面板能画几行"无关：内存固定留 CONFIG.LOG.MAX_LINES（超出删最前面的），
    --   面板自己从尾部取可见行数画（否则往回翻什么都看不到）。

    -- 布局摘要进 debug 日志：屏幕上的错位抄不回来，排错时靠这行数字。
    logs.debug(string.format("[调试] 布局 控制 %dx%d@%d,%d 状态 %dx%d@%d,%d 图表 %dx%d@%d,%d 日志 %dx%d@%d,%d",
        fstate.areas.control.w, fstate.areas.control.h, fstate.areas.control.x, fstate.areas.control.y,
        fstate.areas.status.w, fstate.areas.status.h, fstate.areas.status.x, fstate.areas.status.y,
        fstate.areas.chart.w, fstate.areas.chart.h, fstate.areas.chart.x, fstate.areas.chart.y,
        fstate.areas.log.w, fstate.areas.log.h, fstate.areas.log.x, fstate.areas.log.y))

    -- 版面变了：旧热区与旧指纹全部作废
    fstate.clearHitboxes()
    fstate.invalidateAll()
end

return layout
