local constants = require("shared.constants")
local state     = require("shared.state")
local rules     = require("backend.domain.rules")
local threshold = {}
function threshold.label() return "阈值调度" end
function threshold.publish()
    local budget = state.power.all or 0
    local top    = state.serviceTop()
    for level = 1, constants.LEVEL_COUNT do
        local n = 0
        if level <= top then
            local count = math.max(1, state.plant(level).deployed or 0)
            local per   = constants.POWER_LEVELS[level] or 0
            if per <= 0 or budget <= 0 then
                n = 1
            else
                n = math.max(1, math.min(constants.parallelCap(level), math.floor(budget / (per * count))))
            end
        end
        state.plant(level).suggest = n
    end
end
function threshold.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then return false end
    if rules.materialBlocked(level) then return false end
    return rules.belowThreshold(level)
end
function threshold.order()
    return state.priorityOrder()
end
function threshold.audit()
    local texts, signature = rules.thresholdNotes()
    local warnText
    if not rules.hasPositiveThreshold() then
        warnText = "所有等级的用户阈值均为 0，暂按低保线执行；请前往【配置】页面设置阈值"
    end
    return texts, signature, warnText
end
return threshold
