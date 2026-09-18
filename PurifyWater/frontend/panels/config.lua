--------------------------------------------------------------------------------
-- frontend/panels/config.lua
--------------------------------------------------------------------------------
-- 【职责】配置页的**上半块**：8 级的「等级 / 勾选 / 维持阈值（kL）」列表
-- 【不做什么】不画键盘（那是 panels/keypad）、不碰后端（提交由 input 发 `level_rules_set`）
-- 【依赖】frontend/{state,theme,widgets,layout}、shared/constants
-- 【被谁用】frontend/render
--
-- 与键盘分成两块：两者共用一个指纹时，每点一下键盘 8 行列表也跟着重画（看着就是闪）。
--   现在列表只认"勾选 / 阈值 / 选中行"，键盘只认"改谁 / 填了什么"。
-- 【单位 kL】界面一律 kL（提交那一刻 ×1000 存成 mB），单位只在表头写一次。
-- 【显示】阈值全量 + 三位逗号 + 右对齐；选中行只换底色，正在敲的数字显示在键盘块的编辑行。
-- 【点击】整行 = 选中它；行内 `[√]` 只切勾选，不算选中。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local fstate    = require("frontend.state")
local theme     = require("frontend.theme")
local widgets   = require("frontend.widgets")
local layout    = require("frontend.layout")

local config    = {}

-- 表格列（级 / 勾选 / 阈值；阈值那列右对齐）
local COL_W     = { 0.16, 0.10, 0.74 }

function config.draw(data)
    local area = fstate.areas.config
    widgets.clearArea(area.x, area.y, area.w, area.h)
    widgets.drawBorder(area.x, area.y, area.w, area.h,
        theme.borderColor(data.system.priority == "high"))
    widgets.drawText(area.x + 2, area.y + 1, "净水厂配置（点某级选中，用下方键盘改阈值）",
        theme.COLORS.TEXT_CYAN)

    local inner                          = { x = area.x + 2, w = area.w - 4 }
    local cols                           = layout.cols(inner, COL_W)
    fstate.checkCells, fstate.configRows = {}, {}

    -- 表头（"阈值 (kL)" 右对齐，跟下面的数字同一侧）
    widgets.drawText(cols[1].x, area.y + 2, "级", theme.COLORS.TEXT_DISABLED)
    widgets.drawText(cols[2].x, area.y + 2, "勾选", theme.COLORS.TEXT_DISABLED)
    widgets.drawTextRight(cols[3].x, cols[3].w, area.y + 2, "阈值 (kL)", theme.COLORS.TEXT_DISABLED)

    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        local y   = area.y + 3 + (level - 1)
        if y > area.y + area.h - 2 then break end

        local sel   = (fstate.configSel == level)
        local rowBg = sel and theme.COLORS.BTN_BG_HOVER or nil
        if sel then widgets.clearArea(inner.x, y, inner.w, 1, theme.COLORS.BTN_BG_HOVER) end

        widgets.drawText(cols[1].x, y, row.label, theme.COLORS.TEXT_CYAN, rowBg)

        -- 勾选格（点它只切换勾选，不选中这一级）
        fstate.checkCells[level] = { x = cols[2].x, y = y, w = 4, h = 1 }
        widgets.drawText(cols[2].x, y, row.rule.enabled and "[√]" or "[  ]",
            row.rule.enabled and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED, rowBg)

        -- 阈值：选中行只换底色表示"正在改这级"，数字仍是当前值（正在敲的数在键盘块的编辑行）
        widgets.drawTextRight(cols[3].x, cols[3].w, y, row.thresholdKText,
            sel and theme.COLORS.TEXT_YELLOW or theme.COLORS.TEXT, rowBg)

        fstate.configRows[level] = { x = area.x, y = y, w = area.w, h = 1 }
    end
end

--- 指纹：边框色依据 + 尺寸 + 每级的"勾选 / 阈值" + 选中行
-- 不含 configBuf：那是键盘块的输入值，放进来会让"点键盘"连带重画列表。
function config.fingerprint(data)
    local area  = fstate.areas.config
    local parts = {
        tostring(data.system.priority),
        tostring(area and area.w or 0), tostring(area and area.h or 0),
        tostring(fstate.configSel or 0)
    }
    for level = 1, constants.LEVEL_COUNT do
        local row         = data.levels[level]
        parts[#parts + 1] = table.concat({
            row.label, tostring(row.rule.enabled), tostring(row.rule.threshold)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end

return config
