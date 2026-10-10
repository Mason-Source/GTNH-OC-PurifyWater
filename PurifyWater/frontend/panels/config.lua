--------------------------------------------------------------------------------
-- frontend/panels/config.lua
--------------------------------------------------------------------------------
-- 【职责】配置页「阈值配置」卡片的**上半块**：卡片边框 + 标题 + 8 级的「等级 / 勾选 / 阈值（kL）」
-- 【不做什么】不画回显/键盘（那是 panels/editline、panels/keypad，它们在**同一张卡内部**）、
--   不碰后端（提交由 input 发 `level_rules_set`）、不画「运行设置」卡（panels/settings）
-- 【依赖】frontend/{state,theme,widgets,layout}、shared/constants
-- 【被谁用】frontend/render
--
-- 与回显/键盘分成三块：共用一个指纹时，每点一下键盘 8 行列表也跟着重画（看着就是闪）。
--   现在列表只认"勾选 / 阈值 / 选中行"，回显只认"改谁 / 填了什么"，键盘只认"改谁"。
-- 【清区范围】只清卡片的**上半**（layout.CONFIG_HEAD_H 行）：卡内下半的回显/键盘各有矩形，
--   这里不能连带擦掉；边框整卡重描一遍（两个内部面板都缩进了 2 列，不碰它）。
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
    -- 只清"卡片上半"（表头 + 8 级）：卡内下半的回显/键盘各自重画，擦掉就白屏了
    widgets.clearArea(area.x, area.y, area.w, layout.CONFIG_HEAD_H)
    widgets.drawBorder(area.x, area.y, area.w, area.h,
        theme.borderColor(data.system.priority == "high"))
    widgets.drawText(area.x + 2, area.y + 1, "阈值配置（点某级选中，用下面键盘改）",
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
        fstate.checkCells[level] = { x = cols[2].x, y = y, w = 3, h = 1 }
        widgets.drawText(cols[2].x, y, row.rule.enabled and "[√]" or "[ ]",
            row.rule.enabled and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED, rowBg)

        -- 阈值：选中行只换底色表示"正在改这级"，数字仍是当前值（正在敲的数在键盘块的编辑行）
        local thresholdColor = sel and theme.COLORS.TEXT_YELLOW
            or (row.thresholdOverridden and theme.COLORS.TEXT_RED or theme.COLORS.TEXT)
        widgets.drawTextRight(cols[3].x, cols[3].w, y, row.thresholdKText,
            thresholdColor, rowBg)

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
