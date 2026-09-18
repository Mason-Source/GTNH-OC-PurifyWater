local constants = require("shared.constants")
local utils     = require("shared.utils")
local state     = require("shared.state")
local power     = require("backend.domain.power")
local rules     = {}
function rules.reserveLine(level)
    return constants.OPEN_RESERVE_MULTIPLIER * power.levelParallel(level)
        * constants.STOCK_PER_PARALLEL
end
function rules.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then
        return { open = false, forced = false, reason = "未部署机器" }
    end
    local own = state.fluids[level]
    if type(own) ~= "number" then
        return { open = false, forced = false, reason = "本级水位读不到" }
    end
    local line = rules.reserveLine(level)
    if level > 1 then
        local prev = state.fluids[level - 1]
        if type(prev) ~= "number" then
            return { open = false, forced = false, reason = "上级水位读不到" }
        end
        if prev < line then
            return {
                open = false,
                forced = false,
                reason = string.format(
                    "原料不足：%s 仅 %s，需 %s",
                    constants.levelLabel(level - 1),
                    utils.formatShortNumber(prev), utils.formatShortNumber(line))
            }
        end
    end
    if own < line then
        return {
            open = true,
            forced = true,
            reason = string.format(
                "强制：本级 %s 低于 5 倍线 %s",
                utils.formatShortNumber(own), utils.formatShortNumber(line))
        }
    end
    local rule = state.rules[level]
    if not rule then
        return { open = false, forced = false, reason = "无阈值配置（文件缺失）" }
    end
    if not rule.enabled then
        return { open = false, forced = false, reason = "未勾选（不受阈值管理）" }
    end
    local threshold = rule.threshold or 0
    if threshold <= 0 then
        return { open = false, forced = false, reason = "未设阈值（0）：不开启" }
    end
    if own >= threshold then
        return {
            open = false,
            forced = false,
            reason = string.format(
                "已到阈值：%s / %s",
                utils.formatShortNumber(own), utils.formatShortNumber(threshold))
        }
    end
    return {
        open = true,
        forced = false,
        reason = string.format(
            "低于阈值：%s / %s",
            utils.formatShortNumber(own), utils.formatShortNumber(threshold))
    }
end
return rules
