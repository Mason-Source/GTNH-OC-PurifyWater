--------------------------------------------------------------------------------
-- frontend/panels/config.lua
--------------------------------------------------------------------------------
-- 【职责】调度配置卡的表格段：边框 + 标题 + 表头 + 8 级 × 5 列
-- 【不做什么】不画键盘（panels/keypad）、不碰后端、不发命令
-- 【依赖】frontend/{state,theme,widgets,layout}、shared/constants
-- 【被谁用】frontend/render
--
-- 8 级 ×（勾选/阈值/权重/增产）一张表；勾选格点即切换，其余列点开对应键盘。
-- 增产是 T7 专属档位，其余行画 -。文字列左对齐、数值列右对齐。
-- 生效性由 system.effectiveConfig() 决定：无效列灰显但照改照存；选中高亮压过灰显。
-- 重画：只清标题+表头与变化的那一行，禁止先整段清空（未变行会永久消失）。
--------------------------------------------------------------------------------

local unicode   = require("unicode")

local constants = require("shared.constants")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")

local config    = {}

-- 列（顺序 = 显示顺序）：key = 可编辑列的字段名；align = "right" 的列右对齐（数值列都右对齐）
local COLS      = {
    { head = "级" },
    { key = "enabled", head = "勾选" },
    { key = "threshold", head = "阈值 kL", align = "right" },
    { key = "weight", head = "权重", align = "right" },
    { key = "boost", head = "增产", align = "right" }
}
local COL_W     = { 0.12, 0.12, 0.38, 0.20, 0.18 }

--- 数值文本：整数不带小数点（1 / 1.25 / 1.5 / 1.75 / 2）
-- @param value number|nil
-- @return string
local function numberText(value)
    value = tonumber(value) or 0
    if value == math.floor(value) then return string.format("%d", value) end
    return string.format("%g", value)
end

--- 画表格段（边框 / 标题 / 表头 / 8 级）；键盘槽由 panels/keypad 画在自己那块矩形里
-- @param data table viewmodel.build() 的返回
function config.draw(data)
    local area = fstate.areas.config
    if not area or area.h < 3 then return end

    local sys   = data.system or {}
    local eff   = sys.effectiveConfig or {}
    local inner = { x = area.x + 2, w = area.w - 4 }
    local cols  = layout.cols(inner, COL_W)

    -- ① 卡框整条画一遍（边框列只由这里画，行内容只在卡内，碰不到它）
    widgets.drawBorder(area.x, area.y, area.w, area.h,
        theme.borderColor(sys.priority == "high"))

    -- ② 标题 + 分隔 + 表头 + 分隔：每次重画（就四行，不值得再做一层指纹）
    --   标题行只写"调度配置"：哪几列现在算数由**列本身的灰/亮**表达，不再写一行说明（太长）
    widgets.clearArea(area.x + 1, area.y + 1, area.w - 2, 4)
    widgets.drawText(area.x + 2, area.y + 1, "调度配置", theme.COLORS.TEXT_CYAN)
    -- 标题行右侧：两个可点开的全局字段，**贴在一起**从右往左排（热区 = 文本本身）
    --   无线范围（左，青色）+ 能源仓利用因子（右，紫色）；点哪个换哪个的数字键盘，编辑中变黄
    local fEditing = (fstate.editField == "factor")
    local fText    = string.format("能源仓利用因子 %s%%",
        fEditing and ((fstate.editBuf or "") .. "_")
        or tostring(math.floor(tonumber(sys.energyFactor) or 100)))
    local sEditing = (fstate.editField == "strength")
    local sText    = string.format("无线范围 %s", sEditing and ((fstate.editBuf or "") .. "_")
        or tostring(math.floor(tonumber((data.net or {}).strength) or 0)))
    local fW       = unicode.wlen(fText)
    local sW       = unicode.wlen(sText)
    local fX       = inner.x + inner.w - fW
    local sX       = fX - sW - 3
    widgets.drawText(fX, area.y + 1, fText,
        fEditing and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT_VIOLET)
    widgets.drawText(sX, area.y + 1, sText,
        sEditing and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT_CYAN)
    fstate.factorCell   = { x = fX, y = area.y + 1, w = fW, h = 1 }
    fstate.strengthCell = { x = sX, y = area.y + 1, w = sW, h = 1 }
    -- 表头行上下各一条细分隔线（暗色）
    widgets.drawText(inner.x, area.y + 2, string.rep("─", inner.w), theme.CHART_AXIS)
    widgets.drawText(inner.x, area.y + 4, string.rep("─", inner.w), theme.CHART_AXIS)
    for index, col in ipairs(COLS) do
        if col.align == "right" then
            widgets.drawTextRight(cols[index].x, cols[index].w, area.y + 3, col.head,
                theme.COLORS.TEXT_DISABLED)
        else
            widgets.drawText(cols[index].x, area.y + 3, col.head, theme.COLORS.TEXT_DISABLED)
        end
    end

    -- 选中的是哪一列（画每行时要给那一格铺底色）
    local selCol = nil
    for index, col in ipairs(COLS) do
        if col.key and col.key == fstate.editField then selCol = index end
    end

    -- ③ 每级一行：**脏了才清这一行 + 画这一行**（没脏的行保持原样，谁都不许先整段清）
    fstate.cells = {}
    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        local y   = area.y + 5 + (level - 1)
        if y > area.y + area.h - 2 then break end

        local sel  = (fstate.editLevel == level)
        -- 这一行画出来的每一样东西（含选中与缓冲）：变了才重画这一行
        local fp   = table.concat({
            row.label, tostring(row.rule.enabled), tostring(row.rule.threshold),
            tostring(row.weight), tostring(row.thresholdOverridden),
            tostring(sys.t7Boost), tostring(sys.mode), tostring(sys.enforceThreshold),
            tostring(sel), tostring(sel and fstate.editField or ""),
            tostring(sel and fstate.editBuf or "")
        }, ":")

        if fstate.subDirty("config", "row" .. level, fp) then
            widgets.clearArea(inner.x, y, inner.w, 1)
            local rowBg = sel and theme.COLORS.BTN_BG_HOVER or nil
            local function cellBg(index)
                return (sel and selCol == index) and theme.COLORS.BTN_BG_HOVER or nil
            end
            if sel and selCol then
                widgets.clearArea(cols[selCol].x, y, cols[selCol].w, 1, theme.COLORS.BTN_BG_HOVER)
            end

            -- ① 级（文字列：左对齐）
            widgets.drawText(cols[1].x, y, row.label, theme.COLORS.TEXT_CYAN, rowBg)

            -- ② 勾选（文字列：左对齐）：**点一下直接切换**（不算选中）；生效且勾选 = 绿，其余灰
            local mark      = row.rule.enabled and "[√]" or "[ ]"
            local markColor = (row.rule.enabled and eff.enabled)
                and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED
            widgets.drawText(cols[2].x, y, mark, markColor, cellBg(2))

            -- ③ 阈值（kL，数值列：右对齐）：选中时显示输入缓冲；被保供线顶掉时标红
            local thrText  = row.thresholdKText or "-"
            local thrColor = eff.threshold
                and (row.thresholdOverridden and theme.COLORS.TEXT_RED or theme.COLORS.TEXT)
                or theme.COLORS.TEXT_DISABLED
            if sel and fstate.editField == "threshold" then
                thrText, thrColor = (fstate.editBuf or "") .. "_", theme.COLORS.TEXT_YELLOW
            end
            widgets.drawTextRight(cols[3].x, cols[3].w, y, thrText, thrColor, cellBg(3))

            -- ④ 权重（数值列：右对齐）：选中时显示输入缓冲
            local wText  = tostring(row.weight or 0)
            local wColor = eff.weight and theme.COLORS.TEXT or theme.COLORS.TEXT_DISABLED
            if sel and fstate.editField == "weight" then
                wText, wColor = (fstate.editBuf or "") .. "_", theme.COLORS.TEXT_YELLOW
            end
            widgets.drawTextRight(cols[4].x, cols[4].w, y, wText, wColor, cellBg(4))

            -- ⑤ 增产（数值列：右对齐）：T7 专属的全局档位，其它行画 `-` 占位
            local isT7    = (level == constants.T7_LEVEL)
            local bText   = isT7 and numberText(sys.t7Boost) or "-"
            local bColor  = (not isT7) and theme.COLORS.TEXT_DISABLED
                or ((sel and fstate.editField == "boost") and theme.COLORS.TEXT_YELLOW
                    or (eff.boost and theme.COLORS.TEXT or theme.COLORS.TEXT_DISABLED))
            widgets.drawTextRight(cols[5].x, cols[5].w, y, bText, bColor, cellBg(5))
        end

        -- 热区每帧都登记（勾选格 = 点一下切换；阈值 / 权重格 = 点一下选中；"增产"只有 T7 那一行有）
        fstate.cells[level] = {
            enabled   = { x = cols[2].x, y = y, w = cols[2].w, h = 1 },
            threshold = { x = cols[3].x, y = y, w = cols[3].w, h = 1 },
            weight    = { x = cols[4].x, y = y, w = cols[4].w, h = 1 },
            boost     = (level == constants.T7_LEVEL)
                and { x = cols[5].x, y = y, w = cols[5].w, h = 1 } or nil
        }
    end
end

--- 指纹（面板级开关）：**必须是行级子指纹的超集** —— 漏了哪样，那一行就永远不会重画
-- 尺寸/坐标一起进：换分辨率后 layout 会强制整屏重画，这里再兜一层。
-- @param data table
-- @return string
function config.fingerprint(data)
    local area  = fstate.areas.config or {}
    local sys   = (data and data.system) or {}
    local eff   = sys.effectiveConfig or {}
    local parts = {
        tostring(area.x or 0), tostring(area.y or 0), tostring(area.w or 0), tostring(area.h or 0),
        tostring(sys.priority), tostring(sys.mode), tostring(sys.enforceThreshold),
        tostring(sys.t7Boost), tostring(sys.energyFactor), tostring((data.net or {}).strength),
        tostring(eff.enabled), tostring(eff.threshold),
        tostring(eff.weight), tostring(eff.boost),
        tostring(fstate.editLevel or 0), tostring(fstate.editField or ""),
        tostring(fstate.editBuf or "")
    }
    for level = 1, constants.LEVEL_COUNT do
        local row         = data.levels[level]
        parts[#parts + 1] = table.concat({
            row.label, tostring(row.rule.enabled), tostring(row.rule.threshold),
            tostring(row.weight), tostring(row.thresholdOverridden)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end

return config
