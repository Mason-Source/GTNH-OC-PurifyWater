--------------------------------------------------------------------------------
-- frontend/panels/config.lua
--------------------------------------------------------------------------------
-- 【职责】配置页「调度配置」卡的**表格段**：边框 + 标题（带"哪几列生效"）+ 表头 + 8 级 × 5 列
-- 【不做什么】不画键盘（那是 panels/keypad，在同一张卡的**固定键盘槽**里）、不碰后端、不发命令
-- 【依赖】frontend/{state,theme,widgets,layout}、shared/constants
-- 【被谁用】frontend/render
--
-- 【一张表管全部】8 级 ×（勾选 / 阈值 / 权重 / 增产）都在这里：
--   **勾选格点一下就直接切换**（老习惯，不选中、不开键盘）；其余列点一格 = 选中它，
--   卡内键盘槽随即换成**那一列自己的键盘**。表里不再有「建议并行」—— 建议在总览页每级行上看，
--   配置页只放"能改的东西"（一条信息只有一个地方显示，少一处就少一处要维护的对齐）。
--   「增产」是 T7 专属的全局档位（1 / 1.25 / 1.5 / 1.75 / 2）：只有 T7 那一行有值，其余行画 `-`。
-- 【对齐】文字列（级 / 勾选）左对齐，**数值列（阈值 / 权重 / 增产）一律右对齐**，表头跟数值同侧。
-- 【生效性】system.effect() 说哪几列当前模式算数：不算数的整列灰显，但**照画照改**（保存待用）——
--   灰显只是"现在用不到"，不是"禁改"；选中高亮压过灰显。
-- 【格内缓冲】正在改的那一格显示输入缓冲 + 一个下划线，不再单独占一行回显。
--
-- 【重画规矩（踩过的坑）】面板重画时**只清"标题 + 表头"那两行**，每级那一行由它自己的子指纹决定
--   "清这一行 + 画这一行"。**绝不能先整段清空**：选中态一变（editLevel/editField/editBuf）面板就会
--   重画，而那些没变的行会被擦掉却永远不再重画 —— 屏幕上就是"其它行全没了"。
--------------------------------------------------------------------------------

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
    { key = "threshold", head = "阈值(kL)", align = "right" },
    { key = "weight", head = "权重", align = "right" },
    { key = "boost", head = "增产", align = "right" }
}
local COL_W     = { 0.12, 0.12, 0.38, 0.20, 0.18 }

--- 标题行右侧那句"现在哪几列算数"（纯展示：判据来自后端 system.effect）
-- @param sys table api.read.system()
-- @return string
local function effectText(sys)
    local eff  = (sys and sys.effect) or {}
    local on, off = {}, {}
    for _, item in ipairs({
        { "enabled", "勾选" }, { "threshold", "阈值" },
        { "weight", "权重" }, { "boost", "增产" }
    }) do
        if eff[item[1]] then on[#on + 1] = item[2] else off[#off + 1] = item[2] end
    end

    local head = (sys and sys.mode == "rate")
        and ("速率调度" .. (sys.enforceThreshold and "（受阈值约束）" or "（不受阈值约束）"))
        or "阈值调度"
    local text = head .. "："
        .. ((#on > 0) and (table.concat(on, "/") .. " 生效") or "没有列生效")
    if #off > 0 then text = text .. "，" .. table.concat(off, "/") .. " 待用" end
    return text
end

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
    local eff   = sys.effect or {}
    local inner = { x = area.x + 2, w = area.w - 4 }
    local cols  = layout.cols(inner, COL_W)

    -- ① 卡框整条画一遍（边框列只由这里画，行内容只在卡内，碰不到它）
    widgets.drawBorder(area.x, area.y, area.w, area.h,
        theme.borderColor(sys.priority == "high"))

    -- ② 标题行（含"哪几列生效"）+ 表头行：每次重画（就两行文字，不值得再做一层指纹）
    widgets.clearArea(area.x + 1, area.y + 1, area.w - 2, 2)
    widgets.drawText(area.x + 2, area.y + 1, "调度配置", theme.COLORS.TEXT_CYAN)
    widgets.drawText(area.x + 12, area.y + 1, effectText(sys), theme.COLORS.TEXT_DISABLED)
    for index, col in ipairs(COLS) do
        if col.align == "right" then
            widgets.drawTextRight(cols[index].x, cols[index].w, area.y + 2, col.head,
                theme.COLORS.TEXT_DISABLED)
        else
            widgets.drawText(cols[index].x, area.y + 2, col.head, theme.COLORS.TEXT_DISABLED)
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
        local y   = area.y + 3 + (level - 1)
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
    local eff   = sys.effect or {}
    local parts = {
        tostring(area.x or 0), tostring(area.y or 0), tostring(area.w or 0), tostring(area.h or 0),
        tostring(sys.priority), tostring(sys.mode), tostring(sys.enforceThreshold),
        tostring(sys.t7Boost), tostring(eff.enabled), tostring(eff.threshold),
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
