local constants = require("shared.constants")
local state     = require("shared.state")
local rules     = require("backend.domain.rules")
local rates     = require("backend.domain.rates")
local rate      = {}
function rate.label() return "速率调度" end
function rate.publish()
    local plan = rates.plan()
    for level = 1, constants.LEVEL_COUNT do
        state.plant(level).suggest = plan.suggest[level] or 0
    end
    state.planNotes = plan.notes or {}
end
function rate.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then return false end
    if state.serviceTop() < level then return false end
    if not rates.wanted(level) then return false end
    if rules.materialBlocked(level) then return false end
    if state.system.enforceThreshold then return rules.belowThreshold(level) end
    return true
end
function rate.order()
    return state.priorityOrder()
end
function rate.audit()
    local texts, sigs, debugTexts = {}, {}, {}
    if state.system.enforceThreshold then
        local notes, sig = rules.thresholdNotes()
        for _, text in ipairs(notes) do texts[#texts + 1] = text end
        if sig ~= "" then sigs[#sigs + 1] = sig end
    end
    for _, note in ipairs(state.planNotes or {}) do
        local label = constants.levelLabel(note.level)
        if note.kind == "too_small" then
            texts[#texts + 1] = string.format(
                "速率模式：功率不足，%s 按比例分不到 1 并行（本轮不开）", label)
        elseif note.kind == "cap_bound" then
            texts[#texts + 1] = string.format(
                "速率模式：%s 已达单机并行上限，整体并行由它决定（其余等级按同一比例缩小）", label)
        elseif note.kind == "clip" then
            texts[#texts + 1] = string.format(
                "速率模式：%s 建议并行被单机上限夹取（比例会失真）", label)
        elseif note.kind == "trimmed" then
            debugTexts[#debugTexts + 1] = string.format(
                "[调试] 速率模式：%s 建议并行 %s → %s（上游 %s 只够供这么多，避免抽干它）",
                label, tostring(note.from), tostring(note.to),
                constants.levelLabel(math.max(1, note.level - 1)))
        end
        sigs[#sigs + 1] = string.format("%s:%d", note.kind, note.level)
    end
    local warnText
    if state.serviceTop() <= 0 then
        warnText = "速率模式：T1澄清 未部署，无可行方案（建议并行全 0）"
    elseif rates.allZero() then
        warnText = "速率模式：在役等级权重全为 0，无生产计划（请到配置页填权重）"
    elseif state.system.enforceThreshold and not rules.hasPositiveThreshold() then
        warnText = "所有等级的用户阈值均为 0，暂按低保线执行；请前往【配置】页面设置阈值"
    end
    return texts, table.concat(sigs, "|"), warnText, debugTexts
end
return rate
