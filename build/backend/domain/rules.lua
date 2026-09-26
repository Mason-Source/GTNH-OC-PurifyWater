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
    local own  = rules.reserveLine(level)
    local next = 0
    if level < constants.LEVEL_COUNT then
        next = rules.reserveLine(level + 1)
    end
    return {
        own        = own,
        next       = next,
        user       = user,
        actual     = math.max(user, next),
        fromNext   = next > user,
        overridden = user > 0 and user < next
    }
end
function rules.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then
        return { open = false, forced = false, reason = "未部署机器" }
    end
    local own = state.fluids[level]
    local line = rules.lines(level)
    if level > 1 then
        local prev = state.fluids[level - 1]
        if prev < line.own then
            return {
                open = false,
                forced = false,
                reason = string.format(
                    "原料不足：%s 仅 %s，需 %s",
                    constants.levelLabel(level - 1),
                    utils.formatShortNumber(prev), utils.formatShortNumber(line.own))
            }
        end
    end
    if own < line.actual then
        local why = line.fromNext
            and ("保供下一级：低于 5 倍线 " .. utils.formatShortNumber(line.next))
            or ("低于阈值：低于 " .. utils.formatShortNumber(line.actual))
        return {
            open = true,
            forced = line.fromNext,
            reason = string.format("%s（本级 %s）", why, utils.formatShortNumber(own))
        }
    end
    return {
        open = false,
        forced = false,
        reason = string.format(
            "已达实际阈值：%s / %s",
            utils.formatShortNumber(own), utils.formatShortNumber(line.actual))
    }
end
function rules.refreshAll()
    for level = 1, constants.LEVEL_COUNT do
        local verdict                           = rules.evaluate(level)
        local snap                              = state.plant(level)
        snap.openable, snap.forced, snap.reason = verdict.open, verdict.forced, verdict.reason
    end
end
return rules
