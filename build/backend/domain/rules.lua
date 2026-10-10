local constants = require("shared.constants")
local utils     = require("shared.utils")
local state     = require("shared.state")
local power     = require("backend.domain.power")
local rules     = {}
function rules.reserveLine(level)
    return constants.OPEN_RESERVE_MULTIPLIER * power.levelParallel(level)
        * constants.STOCK_PER_PARALLEL
end
function rules.lines(level)
    local rule = state.rules[level]
    local user = 0
    if rule and rule.enabled and (rule.threshold or 0) > 0 then
        user = rule.threshold
    end
    local nextLine = 0
    if level < constants.LEVEL_COUNT then
        nextLine = rules.reserveLine(level + 1)
    end
    return {
        next       = nextLine,
        user       = user,
        actual     = math.max(user, nextLine),
        overridden = user > 0 and user < nextLine
    }
end
function rules.materialBlocked(level)
    if level <= 1 then return false end
    return state.fluids[level - 1] < rules.reserveLine(level)
end
function rules.belowThreshold(level)
    return state.fluids[level] < rules.lines(level).actual
end
function rules.hasPositiveThreshold()
    for level = 1, state.serviceTop() do
        local rule = state.rules[level]
        if rule and (rule.threshold or 0) > 0 then return true end
    end
    return false
end
function rules.thresholdNotes()
    local texts, sig = {}, {}
    for level = 1, state.serviceTop() do
        local line = rules.lines(level)
        if line.overridden then
            texts[#texts + 1] = string.format(
                "%s 用户阈值 %s 低于下一级保供线 %s，实际按 %s 执行",
                constants.levelLabel(level),
                utils.formatShortNumber(line.user),
                utils.formatShortNumber(line.next),
                utils.formatShortNumber(line.actual))
            sig[#sig + 1] = table.concat({ level, line.user, line.next }, ":")
        end
    end
    return texts, table.concat(sig, "|")
end
return rules
