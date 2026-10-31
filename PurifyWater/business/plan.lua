-- 贪心调度：纯计算，只读内存快照；不写状态、不碰组件、不发事件。
local constants = require("shared.constants")
local suggest = require("business.suggest")

local plan = {}

function plan.serviceTop(snapshot)
    return suggest.serviceTop(snapshot)
end

function plan.adopted(snapshot, level)
    local learned = (snapshot.plan.learned or {})[level]
    local value = learned and tonumber(learned.parallel) or nil
    if value and value > 0 then return value, "measured" end
    return math.floor(tonumber((snapshot.plan.suggest or {})[level]) or 0), "suggest"
end

function plan.levelParallel(snapshot, level)
    local parallel = plan.adopted(snapshot, level)
    local deployed = tonumber(((snapshot.facts.levels or {})[level] or {}).deployed) or 0
    return parallel * math.max(0, deployed)
end

function plan.levelPower(snapshot, level)
    return plan.levelParallel(snapshot, level) * (constants.POWER_LEVELS[level] or 0)
end

function plan.reserveLine(snapshot, level)
    return constants.OPEN_RESERVE_MULTIPLIER * plan.levelParallel(snapshot, level)
        * constants.STOCK_PER_PARALLEL
end

function plan.lines(snapshot, level)
    local enabled = (snapshot.settings.enabledLevels or {})[level] ~= false
    local raw = tonumber((snapshot.settings.thresholds or {})[level]) or 0
    local user = enabled and raw > 0 and raw or 0
    local nextLine = 0
    if level < constants.LEVEL_COUNT then nextLine = plan.reserveLine(snapshot, level + 1) end
    return {
        next = nextLine,
        user = user,
        actual = math.max(user, nextLine),
        overridden = user > 0 and user < nextLine,
    }
end

local function waterAt(snapshot, level)
    local values = snapshot.facts.water.value
    return values and tonumber(values[level]) or nil
end

function plan.materialBlocked(snapshot, level)
    if level <= 1 then return false end
    local previous = waterAt(snapshot, level - 1)
    if previous == nil then return true end
    return previous < plan.reserveLine(snapshot, level)
end

function plan.belowThreshold(snapshot, level)
    local water = waterAt(snapshot, level)
    if water == nil then return false end
    return water < plan.lines(snapshot, level).actual
end

local function produceBlocked(snapshot, level, produceReady)
    local product = (snapshot.produce.levels or {})[level] or {}
    if product.enabled ~= true then return false end
    return not ((produceReady or {})[level] == true)
end

function plan.evaluate(snapshot, level, produceReady)
    local top = plan.serviceTop(snapshot)
    local deployed = tonumber(((snapshot.facts.levels or {})[level] or {}).deployed) or 0
    if deployed <= 0 or level > top then return false end
    if plan.adopted(snapshot, level) <= 0 then return false end
    if produceBlocked(snapshot, level, produceReady) then return false end
    if plan.materialBlocked(snapshot, level) then return false end

    local mode = snapshot.settings.mode == "rate" and "rate" or "threshold"
    if mode == "threshold" then return plan.belowThreshold(snapshot, level) end
    if not suggest.wanted(snapshot, level, top) then return false end
    if snapshot.settings.enforceThreshold == true then return plan.belowThreshold(snapshot, level) end
    return true
end

function plan.order(snapshot)
    local order = {}
    if snapshot.settings.priority == "high" then
        for level = constants.LEVEL_COUNT, 1, -1 do order[#order + 1] = level end
    else
        for level = 1, constants.LEVEL_COUNT do order[#order + 1] = level end
    end
    return order
end

function plan.compute(snapshot, produceReady)
    local budget = math.max(0, tonumber(snapshot.power.available) or 0)
    local remaining = budget
    local levels, opened = {}, {}
    for level = 1, constants.LEVEL_COUNT do levels[level] = false end

    if budget > 0 then
        for _, level in ipairs(plan.order(snapshot)) do
            local open = plan.evaluate(snapshot, level, produceReady)
            local cost = plan.levelPower(snapshot, level)
            if open and cost > remaining then open = false end
            levels[level] = open
            if open then
                remaining = remaining - cost
                opened[#opened + 1] = level
            end
        end
    end

    return {
        levels = levels,
        opened = opened,
        budget = budget,
        remaining = remaining,
        used = budget - remaining,
    }
end

function plan.inputKey(snapshot, produceReady)
    local parts = {
        tostring(snapshot.settings.mode == "rate" and "rate" or "threshold"),
        tostring(snapshot.settings.priority == "high" and "high" or "low"),
        tostring(snapshot.settings.enforceThreshold == true),
        tostring(math.floor(tonumber(snapshot.power.available) or 0)),
    }
    for level = 1, constants.LEVEL_COUNT do
        local row = (snapshot.facts.levels or {})[level] or {}
        local learned = (snapshot.plan.learned or {})[level] or {}
        local water = waterAt(snapshot, level)
        parts[#parts + 1] = table.concat({
            tostring(math.floor(tonumber(row.deployed) or 0)),
            tostring(math.floor(tonumber((snapshot.plan.suggest or {})[level]) or 0)),
            tostring(math.floor(tonumber(learned.parallel) or 0)),
            water ~= nil and tostring(math.floor(water)) or "-",
            tostring(math.floor(tonumber((snapshot.settings.thresholds or {})[level]) or 0)),
            tostring((snapshot.settings.enabledLevels or {})[level] ~= false),
            tostring(math.floor(suggest.weightOf(snapshot, level))),
            tostring(((snapshot.produce.levels or {})[level] or {}).enabled == true),
            tostring((produceReady or {})[level] == true),
        }, ":")
    end
    return table.concat(parts, "|")
end

function plan.sameLevels(a, b)
    for level = 1, constants.LEVEL_COUNT do
        if ((a or {})[level] == true) ~= ((b or {})[level] == true) then return false end
    end
    return true
end

function plan.copyLevels(values)
    local out = {}
    for level = 1, constants.LEVEL_COUNT do out[level] = (values or {})[level] == true end
    return out
end

function plan.describe(levels)
    local on, off = {}, {}
    for level = 1, constants.LEVEL_COUNT do
        local list = levels[level] and on or off
        list[#list + 1] = "T" .. level
    end
    if #on == 0 then return "全关" end
    if #off == 0 then return "开 " .. table.concat(on, " ") end
    return "开 " .. table.concat(on, " ") .. " ｜ 关 " .. table.concat(off, " ")
end

return plan