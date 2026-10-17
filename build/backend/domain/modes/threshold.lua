local constants = require("shared.constants")
local state     = require("shared.state")
local rules     = require("backend.domain.rules")
local produce   = require("backend.domain.produce")
local threshold = {}
function threshold.label() return "阈值调度" end
function threshold.publish()
    local budget = state.read.powerAll()
    local top    = state.serviceTop()
    for level = 1, constants.LEVEL_COUNT do
        local n = 0
        if level <= top then
            local count = math.max(1, state.read.plant(level).deployed or 0)
            local per   = constants.POWER_LEVELS[level] or 0
            if per <= 0 or budget <= 0 then
                n = 1
            else
                n = math.max(1, math.min(constants.parallelCap(level), math.floor(budget / (per * count))))
            end
        end
        state.write.publishSuggest(level, n)
    end
end
function threshold.evaluate(level)
    local snap = state.read.plant(level)
    if (snap.deployed or 0) <= 0 then return false end
    if produce.blocked(level) then return false end
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
        warnText = "阈值模式：用户阈值全为 0，按低保线执行（请到配置页设置阈值）"
    end
    return texts, signature, warnText
end
return threshold
