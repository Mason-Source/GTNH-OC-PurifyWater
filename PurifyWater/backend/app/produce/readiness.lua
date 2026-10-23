--------------------------------------------------------------------------------
-- backend/app/produce/readiness.lua
--------------------------------------------------------------------------------
-- 【职责】等级就绪性、可开启性、运行期单机门控、界面四态
-- 【不做什么】不做绑定变更、不扫容器、不写盘
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local state     = require("shared.state")

local produce   = require("backend.domain.produce")
local interface = require("backend.domain.produce.interface")
local binding   = require("backend.app.produce.binding")

local readiness = {}

local function methodRate(method)
    return interface.minTransferRate(method)
end

--- 计算某级就绪性（不写 state）
function readiness.evaluate(level)
    local method = produce.method(level)
    local units  = binding.units(level)
    if not method then
        return false, "该级制作自动化尚未实现", units, nil
    end
    local ok, reason = produce.check(level, units, {
        machines = binding.machineSet(level),
        minRate  = methodRate(method)
    })
    return ok, reason, units, method
end

--- 刷新单级 valid 状态
function readiness.refreshLevel(level)
    local ok, reason, units = readiness.evaluate(level)
    state.write.produceSetLevel(level, { valid = ok, validReason = reason or "" })
    return ok, reason, units
end

--- 刷新全部等级的 valid 状态
function readiness.refreshAll()
    local changed = false
    for level = 1, constants.LEVEL_COUNT do
        local before = state.read.produceLevel(level).valid == true
        readiness.refreshLevel(level)
        local after = state.read.produceLevel(level).valid == true
        if before ~= after then changed = true end
    end
    return changed
end

--- 开闸前检查：就绪 + 每台机器侧位已配置 + 未 forceOff
function readiness.validateForEnable(level)
    local ok, reason, units = readiness.refreshLevel(level)
    if not ok then
        return false, string.format("%s 制作自动化未就绪：%s",
            constants.levelLabel(level), tostring(reason)), units
    end
    for _, b in ipairs(state.read.produce().binds) do
        if b.level == level then
            local sub = state.read.produce().subs[b.machine]
            if not (sub and sub.sides) then
                return false, string.format("%s 制作自动化未就绪：侧位尚未自动配置（机器 %s）",
                    constants.levelLabel(level), binding.machineTextOf(level, b.machine)), units
            end
            if sub.forceOff == true then
                return false, string.format("%s 制作自动化原料不足：%s（机器 %s）",
                    constants.levelLabel(level), tostring(sub.forceReason or "原料不足"),
                    binding.machineTextOf(level, b.machine)), units
            end
        end
    end
    return true, nil, units
end

--- 运行期单机门控
function readiness.machineAllowed(machine, level, expectedSub)
    local entry = state.read.produceLevel(level)
    if entry.enabled ~= true or entry.valid ~= true then return false end
    local sub = state.read.produce().subs[machine]
    if not sub or sub.level ~= level or (expectedSub and sub ~= expectedSub) then return false end
    if not sub.sides or sub.forceOff == true then return false end
    local rate = tonumber(sub.rate)
    if not rate or rate <= 0 then return false end
    local method = produce.method(level)
    local minRate = methodRate(method)
    if minRate and rate < minRate then return false end
    if rate * (tonumber(CONFIG.PRODUCE.CHUNK_RATIO) or 0.05) < 1 then return false end
    local fact = binding.observedMachine(level, machine)
    return fact ~= nil and fact.active == true
end

--- 界面四态
function readiness.stateOf(level)
    local entry = state.read.produceLevel(level)
    if entry.valid ~= true then return "invalid", entry.validReason or "未就绪" end
    if entry.enabled ~= true then return "off", nil end
    for _, sub in pairs(state.read.produce().subs) do
        if sub.level == level and sub.forceOff == true then
            return "blocked", sub.forceReason or "原料不足"
        end
    end
    return "ok", nil
end

return readiness
