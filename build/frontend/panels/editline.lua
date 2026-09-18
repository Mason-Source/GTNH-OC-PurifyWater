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
function editline.fingerprint(data)
    local area = fstate.areas.editline
    return table.concat({
        tostring(area and area.w or 0), tostring(fstate.configSel or 0),
        tostring(fstate.configBuf or "")
    }, "\x1f")
end
return editline
