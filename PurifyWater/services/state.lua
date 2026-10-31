-- 最小运行数据；字段形状按前端功能面预留，未接入的更新保持默认值。
local state = {}

local data = {
    revision = 0,
    startedAt = 0,
    time = { now = 0, updatedAt = 0 },

    facts = {
        hardware = { value = nil, observedAt = 0 },
        water = { value = nil, observedAt = 0 },
        host = {
            switch = { value = nil, observedAt = 0 },
            active = { value = nil, observedAt = 0 },
            progress = { value = nil, observedAt = 0 },
            progressMax = { value = nil, observedAt = 0 },
            cycle = { seq = 0, detectedAt = 0 },
        },
        machines = {},
        levels = {},
    },

    settings = {
        mode = "threshold",
        priority = "low",
        enforceThreshold = true,
        theme = "dark",
        energyFactor = 100,
        weights = {},
        thresholds = {},
        enabledLevels = {},
        reflux = {},
        t6DualLithium = false,
        t7Boost = 1,
        autostart = false,
        autostartStale = false,
        autostartPath = nil,
        netEnabled = false,
        netStrength = 20,
    },

    control = {
        session = "stopped",
        awaiting = false,
        awaitingReason = nil,
        stopReason = nil,
        startReason = nil,
        suggestBaseline = nil,
    },

    plan = {
        suggest = {},
        learned = {},
        levels = {},
        budget = 0,
        used = 0,
    },

    power = {
        max = 0,
        available = 0,
        used = 0,
    },

    net = {
        enabled = false,
        available = false,
        strength = 0,
        frame = 0,
    },

    produce = {
        levels = {},
        binding = nil,
        bindings = {},
        candidates = {},
        online = {},
    },

    output = {
        history = { capacity = 80, interval = 30, head = 0, count = 0, values = {} },
        net = {},
    },

    work = {
        hardware = { dueAt = 0 },
        produce = { dueAt = 0, activeCycle = 0, tasks = {}, last = nil },
        schedule = { dueAt = 0 },
        produce_runtime = { dueAt = 0 },
        history = { dueAt = 0 },
        net = { dueAt = 0 },
        log_flush = { dueAt = 0 },
    },
}

function state.get()
    return data
end

function state.setNow(now)
    now = tonumber(now) or 0
    data.time.now = now
    data.time.updatedAt = now
end

function state.start(now)
    now = tonumber(now) or 0
    data.startedAt = now
    state.setNow(now)
end

function state.bump()
    data.revision = data.revision + 1
end

function state.revision()
    return data.revision
end

return state
