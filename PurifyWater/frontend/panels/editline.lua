--------------------------------------------------------------------------------
-- frontend/panels/editline.lua
--------------------------------------------------------------------------------
-- 【职责】配置页的**一行输入回显**：正在改谁 + 缓冲（纯数字）
-- 【不做什么】不画列表（panels/config）、不画键盘（panels/keypad）
-- 【依赖】frontend/{state,theme,widgets}
-- 【被谁用】frontend/render
--
-- 单独成块：键盘只跟"选中了谁"有关、不随敲键变；回显独立后每敲一键只有这
--   一行重画，列表与键盘都不动（不再整屏闪）。
-- 缓冲是纯数字串（不带逗号、不带单位）；单位 kL 只在列表表头出现一次。
--------------------------------------------------------------------------------

local fstate   = require("frontend.state")
local theme    = require("frontend.theme")
local widgets  = require("frontend.widgets")

local editline = {}

function editline.draw(data)
    local area = fstate.areas.editline
    widgets.clearArea(area.x, area.y, area.w, area.h)

    local selRow = fstate.configSel and data.levels[fstate.configSel]
    if selRow then
        widgets.drawText(area.x + 2, area.y,
            string.format("正在改 %s   %s_   （点 ✔ 保存，点 ✘ 取消）", selRow.label,
                fstate.configBuf or ""),
            theme.COLORS.TEXT_YELLOW)
    else
        widgets.drawText(area.x + 2, area.y,
            "未选中：点上面任意一级，再用下面的键盘改它", theme.COLORS.TEXT_DISABLED)
    end
end

--- 指纹：尺寸 + 选中 + 缓冲（只有本块随敲键重画）
function editline.fingerprint(data)
    local area = fstate.areas.editline
    return table.concat({
        tostring(area and area.w or 0), tostring(fstate.configSel or 0),
        tostring(fstate.configBuf or "")
    }, "\x1f")
end

return editline
