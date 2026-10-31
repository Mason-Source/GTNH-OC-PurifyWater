-- 调度状态机：建议发布门槛、贪心计划、批量开关命令、漂移与生命周期。
-- 只读内存做裁决；组件调用仅限最终 setWorkAllowed。
local constants = require("shared.constants")
local state = require("services.state")
local log = require("services.log")
local device = require("hardware.device")
local machines = require("hardware.machines")
local control = require("services.control")
local learning = require("services.learning_service")
local suggest = require("business.suggest")
local plan = require("business.plan")
local apply = require("business.apply")
local produce_service = require("services.produce_service")

local service = {}
local seenRevision = -1
local suggestionKey = nil
local suggestionPublished = false
local planKey = nil
local forcePlan = false
local retryAt = 0
local lastApplyAt = 0
local activeTopology = nil
local pendingCommands = nil
local pendingLevels = nil
local pendingShutdown = false
local pendingReason = nil

local function data()
    return state.get()
end

local function machinesByLevel()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do out[level] = machines.of(level) end
    return out
end

local function topologyKey()
    local parts = {}
    for level = 1, constants.LEVEL_COUNT do
        local addresses = {}
        for _, machine in ipairs(machines.of(level)) do addresses[#addresses + 1] = machine.address end
        table.sort(addresses)
        parts[#parts + 1] = tostring(level) .. ":" .. table.concat(addresses, ",")
    end
    return table.concat(parts, "|")
end


local function produceReadiness()
    local ready = {}
    local levels = data().produce.levels or {}
    for level = 1, constants.LEVEL_COUNT do
        local product = levels[level] or {}
        if product.enabled == true then
            ready[level] = produce_service.canEnable(level)
        else
            ready[level] = false
        end
    end
    return ready
end

local function publishSuggestionIfChanged(force)
    local snapshot = data()
    local key = suggest.inputKey(snapshot)
    if not force and suggestionKey == key then return false end
    suggestionKey = key
    local result = suggest.compute(snapshot)
    local firstPublish = not suggestionPublished
    suggestionPublished = true
    if suggest.equals(snapshot.plan.suggest, result.values) then return false end
    local changes = {}
    for level = 1, constants.LEVEL_COUNT do
        local before = tonumber((snapshot.plan.suggest or {})[level]) or 0
        local after = tonumber(result.values[level]) or 0
        if before ~= after then
            changes[#changes + 1] = string.format("%s %d→%d",
                constants.levelCode(level), before, after)
        end
    end
    snapshot.plan.suggest = suggest.copy(result.values)
    state.bump()
    if not firstPublish and #changes > 0 then
        log.warn("建议并行变动：" .. table.concat(changes, "，"))
    end
    return true
end

local function clearPlan()
    local snapshot = data()
    snapshot.plan.levels = {}
    snapshot.plan.budget = 0
    snapshot.plan.used = 0
    snapshot.power.used = 0
    planKey = nil
    forcePlan = false
end

local function queueShutdown(reason, awaiting)
    local snapshot = data()
    if awaiting then control.awaitUser(snapshot, reason) else control.stop(snapshot, reason) end
    learning.resetAll()
    clearPlan()
    pendingShutdown = true
    retryAt = 0
    pendingReason = tostring(reason or "停机")
    pendingCommands = apply.shutdown(machinesByLevel())
    pendingLevels = {}
    for level = 1, constants.LEVEL_COUNT do pendingLevels[#pendingLevels + 1] = level end
    activeTopology = nil
    state.bump()
    if awaiting then
        log.warn("调度已暂停：等待用户处理（" .. tostring(pendingReason) .. "）")
    else
        log.system(string.format("系统停机：%s", tostring(pendingReason)))
    end
end

local function awaitWithoutShutdown(reason)
    local snapshot = data()
    control.awaitUser(snapshot, reason)
    learning.resetAll()
    clearPlan()
    pendingCommands = nil
    pendingLevels = nil
    pendingShutdown = false
    retryAt = 0
    activeTopology = nil
    state.bump()
    log.warn("调度已暂停：等待用户处理（" .. tostring(reason) .. "）")
end

local function hardStop(reason)
    queueShutdown(reason, false)
end

local function checkHardConditions()
    local snapshot = data()
    if not control.isRunning(snapshot) then return false end
    local hardware = snapshot.facts.hardware or {}
    if hardware.value == nil then
        hardStop("硬件事实失效")
        return true
    end
    if #(hardware.missing or {}) > 0 then
        hardStop("硬件缺失：" .. table.concat(hardware.missing or {}, "、"))
        return true
    end
    if (snapshot.facts.water or {}).value == nil then
        hardStop("水位事实失效")
        return true
    end
    if snapshot.facts.host.switch.value == false then
        hardStop("主机已关机")
        return true
    end
    if activeTopology ~= nil and activeTopology ~= topologyKey() then
        queueShutdown("硬件台账变化", true)
        return true
    end
    return false
end

local function finishPending()
    pendingCommands = nil
    pendingLevels = nil
    pendingShutdown = false
    pendingReason = nil
    retryAt = 0
end

local function executePending(now)
    if pendingCommands == nil then return false end
    local failed, failedLevels = {}, {}
    for _, command in ipairs(pendingCommands) do
        local _, err = device.invoke(command.address, "setWorkAllowed", command.want == true)
        if err then
            failed[#failed + 1] = command
            failedLevels[command.level] = tostring(err)
        end
    end

    if #failed > 0 then
        pendingCommands = failed
        local names = {}
        for level, err in pairs(failedLevels) do names[#names + 1] = constants.levelCode(level) .. ":" .. err end
        table.sort(names)
        log.warn("开关下发失败，稍后重试：" .. table.concat(names, " / "))
        retryAt = now + 1
        return true
    end

    local appliedCount = 0
    for _, level in ipairs(pendingLevels or {}) do
        for _ in ipairs(machines.of(level)) do appliedCount = appliedCount + 1 end
    end
    if #(pendingCommands or {}) == 0 then appliedCount = 0 end
    lastApplyAt = now
    if pendingShutdown then
        log.system(string.format("系统停机：%s（全关完成）", tostring(pendingReason or "-")))
    elseif #(pendingLevels or {}) > 0 then
        log.system(string.format("开关下发完成：%d 台｜%s", appliedCount,
            plan.describe(data().plan.levels)))
    end
    finishPending()
    return true
end

local function checkSwitchDrift()
    if not control.isRunning(data()) then return false end
    if lastApplyAt <= 0 or pendingCommands ~= nil then return false end
    for level = 1, constants.LEVEL_COUNT do
        local levelFact = data().facts.levels[level] or {}
        local observedAt = tonumber(levelFact.switchObservedAt)
        local got = levelFact.switch
        if observedAt and observedAt > lastApplyAt and type(got) == "boolean" then
            local want = data().plan.levels[level] == true
            if got ~= want then
                awaitWithoutShutdown(string.format("%s 开关被人工改动（实测%s，计划%s）",
                    constants.levelCode(level), got and "开" or "关", want and "开" or "关"))
                return true
            end
        end
    end
    return false
end

function service.load()
    seenRevision = -1
    suggestionKey = nil
    suggestionPublished = false
    planKey = nil
    forcePlan = false
    retryAt = 0
    lastApplyAt = 0
    activeTopology = nil
    pendingCommands = nil
    pendingLevels = nil
    pendingShutdown = false
    pendingReason = nil
    learning.resetAll()
end

function service.nextDue(now)
    if pendingCommands ~= nil then
        if retryAt > now then return retryAt end
        return now
    end
    if forcePlan or state.revision() ~= seenRevision then return now end
    return math.huge
end

function service.step(now)
    seenRevision = state.revision()
    if pendingCommands ~= nil and pendingShutdown then return executePending(now) end
    if checkHardConditions() then return true end
    if pendingCommands ~= nil then return executePending(now) end

    local snapshot = data()
    local suggestionChanged = publishSuggestionIfChanged(false)
    if suggestionChanged and control.isRunning(snapshot) then
        local baseline = snapshot.control.suggestBaseline
        if baseline and not suggest.equals(baseline, snapshot.plan.suggest) then
            queueShutdown("建议并行已变化", true)
            return true
        end
        planKey = nil
        forcePlan = true
    end

    if not control.isRunning(snapshot) then return suggestionChanged end

    local ready = produceReadiness()
    local key = plan.inputKey(snapshot, ready)
    if forcePlan or planKey ~= key then
        local forced = forcePlan
        local before = plan.copyLevels(snapshot.plan.levels)
        local result = plan.compute(snapshot, ready)
        local changed = forced or not plan.sameLevels(before, result.levels)
        local numbersChanged = snapshot.plan.budget ~= result.remaining
            or snapshot.plan.used ~= result.used
            or snapshot.power.used ~= result.used
        if changed or numbersChanged then
            snapshot.plan.levels = plan.copyLevels(result.levels)
            snapshot.plan.budget = result.remaining
            snapshot.plan.used = result.used
            snapshot.power.used = result.used
            state.bump()
        end
        planKey = key
        forcePlan = false

        if changed then
            local commands, levels = apply.commands(before, snapshot.plan.levels,
                machinesByLevel(), forced)
            pendingCommands = commands
            pendingLevels = levels
            pendingShutdown = false
            log.system(string.format("调度计划更新：%s｜功率 %s / %s",
                plan.describe(snapshot.plan.levels), tostring(result.used), tostring(result.budget)))
        end
        return true
    end

    return checkSwitchDrift()
end

function service.start(reason)
    local snapshot = data()
    if pendingShutdown then
        pendingCommands = nil
        pendingLevels = nil
        pendingShutdown = false
        pendingReason = nil
        retryAt = 0
        log.warn("用户启动：已取消未完成的停机下发")
    end
    if control.isRunning(snapshot) then return true, nil end
    local ok, err = control.canStart(snapshot)
    if not ok then return false, err end
    publishSuggestionIfChanged(false)
    control.start(snapshot, reason or "手动")
    learning.resetAll()
    activeTopology = topologyKey()
    clearPlan()
    lastApplyAt = 0
    forcePlan = true
    pendingCommands = nil
    pendingLevels = nil
    pendingShutdown = false
    retryAt = 0
    state.bump()
    log.system("系统启动：" .. tostring(reason or "手动"))
    return true, nil
end

function service.shutdownNow(reason)
    local snapshot = data()
    control.stop(snapshot, reason or "程序退出")
    learning.resetAll()
    clearPlan()
    pendingCommands = nil
    pendingLevels = nil
    pendingShutdown = false
    pendingReason = nil
    retryAt = 0
    lastApplyAt = 0
    activeTopology = nil

    local commands = apply.shutdown(machinesByLevel())
    local failed = {}
    for _, command in ipairs(commands) do
        local _, err = device.invoke(command.address, "setWorkAllowed", false)
        if err then
            failed[#failed + 1] = constants.levelCode(command.level) .. ":"
                .. tostring(err)
        end
    end
    state.bump()
    if #failed > 0 then
        log.warn(string.format("退出全关下发失败 %d/%d：%s", #failed, #commands,
            table.concat(failed, " / ")))
        return false, table.concat(failed, " / ")
    end
    log.system(string.format("全关下发完成：%d 台", #commands))
    return true, nil
end
function service.stop(reason)
    if not control.isRunning(data()) then return true, nil end
    queueShutdown(reason or "手动", false)
    return true, nil
end

function service.handle(name, action)
    if name ~= "system_toggle" then return false end
    local reason = tostring((action and action.reason) or "手动")
    if control.isRunning(data()) then
        return true, service.stop(reason)
    end
    return true, service.start(reason)
end

return service