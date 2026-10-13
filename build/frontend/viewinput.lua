local fstate = require("frontend.state")
local view   = {}
function view.chartChip(x, y)
    for level, box in pairs(fstate.chartChips or {}) do
        if fstate.hit(box, x, y) then
            fstate.chartLevel = level
            return true
        end
    end
    return false
end
function view.statusArea(x, y)
    if fstate.currentTab ~= "overview" or not fstate.hit(fstate.areas.status, x, y) then
        return false
    end
    if fstate.detailLevel then
        fstate.detailLevel = nil
    else
        for level, box in pairs(fstate.levelRows or {}) do
            if fstate.hit(box, x, y) then
                fstate.detailLevel = level
                break
            end
        end
    end
    return true
end
function view.quitButton(x, y)
    return fstate.hit(fstate.buttons.quit, x, y)
end
return view
