--------------------------------------------------------------------------------
-- PurifyWater/services/state.lua
--
-- 定位：全工程唯一的运行期状态容器。
-- 功能：定义 facts、settings、control、plan、power、net、produce、output 和 work 的数据形状及 revision。
-- 边界：数据由各领域唯一写者维护；其他模块通过本模块读取共享状态。
--------------------------------------------------------------------------------

local state = {}

-- 状态表按职责分组，每组只允许对应领域写者修改：
-- facts=观测事实，settings=用户设定，control=会话门控，plan=调度计划，
-- power=功率预算，net=广播状态，produce=制作配置，output=派生输出，work=截止时间。
local data = {
    revision = 0,
    startedAt = 0,
    time = { now = 0, updatedAt = 0 },

    -- 最近一次外部观测及其 observedAt；nil 表示未知，不得用 false 或 0 代替。
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

    -- 用户可调参数；持久化格式由 settings_store/config_service 管理。
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

    -- 会话门控；schedule_service 通过 services/control.lua 写入。
    control = {
        session = "stopped",
        awaiting = false,
        awaitingReason = nil,
        stopReason = nil,
        startReason = nil,
        suggestBaseline = nil,
    },

    -- 当前调度计划与学习/建议并行；派生字段不反向冒充观测事实。
    plan = {
        suggest = {},
        learned = {},
        levels = {},
        budget = 0,
        used = 0,
    },

    -- 能源观测与预算：max 为理论功率，available 为折算后的可用功率。
    -- observedAt 只记录成功观测；error 保存最近错误，旧功率继续可用。
    power = {
        max = 0,
        available = 0,
        used = 0,
    },

    -- 无线广播开关、网卡可用性和当前帧号。
    net = {
        enabled = false,
        available = false,
        strength = 0,
        frame = 0,
    },

    -- 制作自动化配置：levels/enabled、绑定表、候选转运器与在线映射。
    produce = {
        levels = {},
        binding = nil,
        bindings = {},
        candidates = {},
        -- nil 表示尚未完成首次转运器扫描；空表表示扫描成功且没有在线项。
        online = nil,
    },

    -- 面向外部的派生输出；history 为固定容量环形缓冲。
    output = {
        history = { capacity = 80, interval = 30, head = 0, count = 0, values = {} },
        net = {},
    },

    -- 固定后台工作表的本地截止时间，不属于业务事实。
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

--- 返回全局运行期状态表引用。
function state.get()
    return data
end

--- 更新当前逻辑时刻及其观测时间。
function state.setNow(now)
    now = tonumber(now) or 0
    data.time.now = now
    data.time.updatedAt = now
end

--- 记录进程启动时间并初始化当前时刻。
function state.start(now)
    now = tonumber(now) or 0
    data.startedAt = now
    state.setNow(now)
end

--- 递增状态 revision，通知前端和网络重新读取。
function state.bump()
    data.revision = data.revision + 1
end

--- 返回当前状态 revision。
function state.revision()
    return data.revision
end

return state
