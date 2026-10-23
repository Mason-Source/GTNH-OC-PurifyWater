--------------------------------------------------------------------------------
-- shared/state.lua
--------------------------------------------------------------------------------
-- 【职责】内存数据的唯一容器：私有数据 + read/write 接口
-- 【不做什么】不含逻辑（判断、计算、IO）
-- 【依赖】shared/constants
-- 【被谁用】backend/hardware 写、backend/domain 读、frontend 只读
-- 原始表不外露：读走 state.read.*，写走 state.write.*（每个 setter 唯一调用者见文件内注释）
--------------------------------------------------------------------------------

local constants = require("shared.constants")

-- 私有数据（唯一可摸这些表的地方）
local F = {
    facts   = { plants = {}, fluids = {}, powerMax = 0 },
    learn   = {},
    config  = { rules = {}, weights = {}, reflux = {}, mode = "threshold", priority = "low",
                enforceThreshold = true, t7Boost = 1, t6DualLithium = false,
                energyFactor = 100, netStrength = 20 },
    session = { running = false, awaiting = false, awaitReason = nil, lastSuggest = nil,
                autostart = false, autostartStale = false, autostartPath = nil },
    plan    = { suggest = {}, lastPlan = {}, notes = {}, budget = 0 },
    chart   = { points = {} },
    net     = { enabled = false, frame = 0, warned = nil },
    tracker = {},
    hostCycle = { lastProgress = nil, progressMax = nil, seq = 0 },
    produce = { levels = {}, subs = {}, binds = {}, binding = nil, online = {} }
}

local state = {}
local read  = {}
local write = {}

--------------------------------------------------------------------------------
-- 读接口（返回内部引用；约定只读）
--------------------------------------------------------------------------------

function read.plant(level)
    local p = F.facts.plants[level]
    if not p then
        p = { deployed = 0 }
        F.facts.plants[level] = p
    end
    return p
end

function read.fluids()   return F.facts.fluids end
function read.powerMax() return F.facts.powerMax or 0 end
function read.energyFactor() return F.config.energyFactor or 100 end
function read.netStrength() return F.config.netStrength or 0 end
--- 全厂可用功率 = 折算最大功率 × 利用因子（读时现算；唯一"最大→可用"换算处）
function read.powerAll()
    return math.floor((F.facts.powerMax or 0) * (F.config.energyFactor or 100) / 100)
end
function read.rules()    return F.config.rules end
function read.weights()  return F.config.weights end
function read.mode()     return F.config.mode end
function read.priority() return F.config.priority end
function read.enforceThreshold() return F.config.enforceThreshold end
function read.t7Boost()  return F.config.t7Boost end
function read.reflux()   return F.config.reflux end
function read.t6DualLithium() return F.config.t6DualLithium == true end
function read.running()  return F.session.running end
function read.awaiting() return F.session.awaiting end
function read.awaitReason() return F.session.awaitReason end
function read.baseline() return F.session.lastSuggest end
function read.autostart() return F.session.autostart end
function read.autostartStale() return F.session.autostartStale end
function read.autostartPath()  return F.session.autostartPath end
function read.learn(level) return F.learn[level] end
function read.suggest(level) return F.plan.suggest[level] or 0 end
function read.lastPlan() return F.plan.lastPlan end
function read.notes()    return F.plan.notes end
function read.budget()   return F.plan.budget or 0 end
function read.chart()    return F.chart end
function read.net()      return F.net end
function read.tracker()  return F.tracker end

--- 主机周期钟（中性数据；produce / tracker / 调度共同消费）
function read.hostCycle() return F.hostCycle end

--- 制作自动化：各级配置 + 子系统表（原始引用；只读约定）
function read.produce() return F.produce end

--- 制作自动化的某级配置（缺省：未启用、未就绪）
-- @param level number
-- @return table { enabled, valid, validReason }
function read.produceLevel(level)
    local l = F.produce.levels[level]
    if not l then
        l = { enabled = false, valid = false, validReason = "无扫描结果" }
        F.produce.levels[level] = l
    end
    return l
end

--- 在役前缀最高等级：T1 起连续部署的最后一级；T1 没机器 = 0。
function read.serviceTop()
    local top = 0
    for level = 1, constants.LEVEL_COUNT do
        if (read.plant(level).deployed or 0) > 0 then
            top = level
        else
            break
        end
    end
    return top
end

--- 低级/高级水优先的扫描顺序
function read.priorityOrder()
    local order = {}
    if F.config.priority == "high" then
        for level = constants.LEVEL_COUNT, 1, -1 do order[#order + 1] = level end
    else
        for level = 1, constants.LEVEL_COUNT do order[#order + 1] = level end
    end
    return order
end

--------------------------------------------------------------------------------
-- 写接口（每个 setter 唯一调用者）
--------------------------------------------------------------------------------

--- facts：T3 观测结果（backend/jobs）。仅覆盖传入的非 nil 键。
function write.recordPlant(level, fields)
    local p = read.plant(level)
    for key, value in pairs(fields or {}) do
        p[key] = value
    end
end

--- facts：开关边沿记录（app/watch）
function write.setLastSwitch(level, value)
    read.plant(level).lastSwitch = value
end

--- facts：水量（jobs T2）
function write.setFluids(values)
    for level = 1, constants.LEVEL_COUNT do
        F.facts.fluids[level] = (values and values[level]) or 0
    end
end

--- facts：能量仓折算最大功率（jobs T1；可用功率由 read.powerAll 现算）
function write.setPowerMax(value)
    F.facts.powerMax = value or 0
end

--- learn：本轮学习值（domain/learning）
function write.learnSet(level, parallel, source, success)
    local l = F.learn[level]
    if not l then l = {} F.learn[level] = l end
    l.parallel, l.source = parallel, source
    if success ~= nil then read.plant(level).success = success end
end

function write.learnClear(level)
    if level then
        local l = F.learn[level]
        if l then l.parallel, l.source = nil, nil end
    else
        for lv = 1, constants.LEVEL_COUNT do write.learnClear(lv) end
    end
end

--- config（store/* 与 app 层）
function write.setRules(t)    F.config.rules = t or {} end
function write.setRuleLevel(level, rule) F.config.rules[level] = rule end
function write.setWeights(t)  F.config.weights = t or {} end
function write.setWeightLevel(level, w) F.config.weights[level] = w end
function write.setReflux(t)   F.config.reflux = t or {} end
function write.setRefluxLevel(level, on) F.config.reflux[level] = (on == true) end
function write.setMode(v)     F.config.mode = v end
function write.setPriority(v) F.config.priority = v end
function write.setEnforce(v)  F.config.enforceThreshold = v end
function write.setBoost(v)    F.config.t7Boost = v end
function write.setT6DualLithium(v) F.config.t6DualLithium = (v == true) end
function write.setEnergyFactor(v) F.config.energyFactor = v end
function write.netSetStrength(v) F.config.netStrength = tonumber(v) or 0 end

--- session（app/system、app/autostart）
function write.setRunning(v)  F.session.running = (v == true) end
function write.setAwaiting(reason)
    F.session.awaiting    = true
    F.session.awaitReason = tostring(reason or "等待处理")
end

function write.clearAwaiting()
    local why = F.session.awaitReason
    F.session.awaiting, F.session.awaitReason = false, nil
    return why
end

function write.setBaseline(v)   F.session.lastSuggest = v end
function write.setAutostart(on, stale, path)
    F.session.autostart      = (on == true)
    F.session.autostartStale = (stale == true)
    F.session.autostartPath  = path
end

--- plan（domain/modes、app/plan、domain/allocator）
function write.publishSuggest(level, value) F.plan.suggest[level] = value end
function write.setLastPlan(t)  F.plan.lastPlan = t end
function write.deleteLastPlanLevel(level) F.plan.lastPlan[level] = nil end
function write.clearPlan()     F.plan.lastPlan = {} end
function write.setNotes(t)     F.plan.notes = t or {} end
function write.setBudget(v)    F.plan.budget = v or 0 end

--- chart（store/history）
function write.chartSetPoints(t) F.chart.points = t or {} end
function write.chartAppend(point) F.chart.points[#F.chart.points + 1] = point end

--- net（hardware/net）
function write.netSetEnabled(v) F.net.enabled = (v == true) end
function write.netSetFrame(v)   F.net.frame = v or 0 end
function write.netSetWarned(v)  F.net.warned = v end

--- tracker（domain/tracker）
function write.trackerSet(address, t) F.tracker[address] = t end
function write.trackerDelete(address) F.tracker[address] = nil end
function write.trackerReset()         F.tracker = {} end

--- produce：某级配置（store/produce_config、app/produce；仅覆盖传入的非 nil 键）
function write.produceSetLevel(level, fields)
    local entry = read.produceLevel(level)
    for key, value in pairs(fields or {}) do entry[key] = value end
end

--- produce：子系统表整体替换（app/produce 的扫描接入）
function write.produceSetSubs(t) F.produce.subs = t or {} end

--- produce：单台子系统的运行期记录（仅覆盖传入的非 nil 键；不存在则忽略）
function write.produceSetSub(addr, fields)
    local sub = F.produce.subs[addr]
    if not sub then return end
    for key, value in pairs(fields or {}) do sub[key] = value end
end

--- 主机周期进度（host_cycle 每次采样原地更新）
function write.setHostCycleProgress(progress, maxProgress)
    F.hostCycle.lastProgress = progress
    F.hostCycle.progressMax = maxProgress
end

--- 主机周期钟（host_cycle 唯一写入口）
function write.setHostCycle(fields)
    for key, value in pairs(fields or {}) do F.hostCycle[key] = value end
end

--- produce：绑定表（数组；只由 app/produce 整表替换：{ {level=, machine=, transposer=}, ... }）
function write.produceSetBinds(list) F.produce.binds = list or {} end

--- produce：正在进行的绑定（{ level, machine, snapshot } | nil）
function write.produceSetBinding(binding) F.produce.binding = binding end

--- produce：已绑定转运器的在线表（只由 app/produce 的在线检查 / 绑定变更时整表替换）
function write.produceSetOnlineAll(map) F.produce.online = map or {} end

--- produce：清掉某台子系统的侧位配置（app/produce 触发"重新配置"时调用）
-- 输出面 sideTarget 不在这里清：粘住，重配置只重算输入侧
function write.produceClearSides(machine)
    local sub = F.produce.subs[machine]
    if not sub then return end
    sub.sides, sub.sideFail = nil, nil
end

--------------------------------------------------------------------------------
-- 兼容出口：派生读函数
--------------------------------------------------------------------------------

state.read           = read
state.write          = write
state.serviceTop     = read.serviceTop
state.priorityOrder  = read.priorityOrder

return state
