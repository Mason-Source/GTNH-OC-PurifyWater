--------------------------------------------------------------------------------
-- backend/app/produce/patrol.lua
--------------------------------------------------------------------------------
-- 【职责】T1 原料巡检：侧位自动配置、流体/物品余量检查、forceOff 维护
-- 【不做什么】不判周期边界、不创建 operation、不下发机器开关
--------------------------------------------------------------------------------

local constants  = require("shared.constants")
local logs       = require("shared.logs")
local state      = require("shared.state")
local utils      = require("shared.utils")

local produce    = require("backend.domain.produce")
local interface  = require("backend.domain.produce.interface")
local binding    = require("backend.app.produce.binding")
local sides      = require("backend.app.produce.sides")
local probes     = require("backend.hardware.probes")
local transposer = require("backend.hardware.transposer")

local patrol = {}

local FORCE_REASON_WIDTH   = 48

--- “任意一种”需求按库存选最大者
local function resolveAnyFound(found, anyList)
    local picked, best = nil, 0
    for _, fluid in ipairs(anyList or {}) do
        local amount = found[fluid] or 0
        if amount > best then picked, best = fluid, amount end
    end
    return picked or (anyList and anyList[1]) or "?"
end

--- 读取流体源余量
local function readFluidStock(sub)
    local found = {}
    for _, side in ipairs(sub.sides.sources or {}) do
        for _, item in ipairs(transposer.containers(sub.transposer, side) or {}) do
            if item.fluid and (not found[item.fluid] or (item.amount or 0) > found[item.fluid]) then
                found[item.fluid] = item.amount or 0
            end
        end
    end
    return found
end

--- 读取物品源余量（每个面只扫一次）
local function readItemStock(sub, stock)
    local wanted, found = {}, {}
    for _, need in ipairs(stock) do
        if need.item then
            wanted[need.item.name .. ":" .. (tonumber(need.item.damage) or 0)] = true
        end
    end
    for _, side in ipairs(sub.sides.itemSources or {}) do
        for _, item in ipairs(transposer.items(sub.transposer, side) or {}) do
            local key = item.name .. ":" .. (tonumber(item.damage) or 0)
            if wanted[key] then
                found[key] = (found[key] or 0) + (tonumber(item.size) or 0)
            end
        end
    end
    return found
end

--- 检查一份库存需求，返回缺失说明
local function checkStock(sub, stock)
    local needFluid, needItem = false, false
    for _, need in ipairs(stock) do
        if need.item then needItem = true else needFluid = true end
    end

    local found = needFluid and readFluidStock(sub) or {}
    local foundItems = needItem and readItemStock(sub, stock) or {}
    local miss = {}
    for _, need in ipairs(stock) do
        if need.item then
            local key = need.item.name .. ":" .. (tonumber(need.item.damage) or 0)
            local have = foundItems[key] or 0
            if have < need.amount then
                miss[#miss + 1] = string.format("%s %d/%d个",
                    tostring(need.label or need.item.label or need.item.name), have, need.amount)
            end
        else
            local fluid = need.fluid or resolveAnyFound(found, need.any)
            local have = fluid and (found[fluid] or 0) or 0
            if have < need.amount then
                miss[#miss + 1] = string.format("%s %d/%dL",
                    tostring(need.label or fluid), have, need.amount)
            end
        end
    end
    return miss
end

--- 自动配置侧位并记录日志
local function configure(machine, sub, method, changed)
    local requiredFluids = interface.requiredFluids(method)
    local requiredItems  = interface.requiredItems(method)
    if (not requiredFluids or #requiredFluids == 0)
        and (not requiredItems or #requiredItems == 0) then
        return changed
    end
    local ok, reason, config = sides.configure(machine, sub, requiredFluids, requiredItems)
    if ok and config then
        return true
    end
    state.write.produceSetSub(machine, { sideFail = reason })
    return changed
end

--- 原料不足时检查容器方位是否变过
local function reconfigureIfMoved(machine, sub, requiredItems)
    local signature = sides.layoutSignature(sub, requiredItems ~= nil and #requiredItems > 0)
    if sub.layout ~= nil and signature ~= sub.layout then
        sides.clear(machine)
        return true
    end
    return false
end

--- 执行某一级的库存判断与 forceOff 状态切换
local function checkMachine(machine, sub, method, changed)
    local stock
    if interface.patrolByNeed(method) then
        local demand = method.need(probes.sensorLines(machine))
        stock = demand ~= nil and demand or nil
    else
        stock = interface.stockRequirements(method)
    end
    if stock == nil then return changed end

    local miss = checkStock(sub, stock)
    local enabled = state.read.produceLevel(sub.level).enabled == true
    local wasOff = sub.forceOff == true
    if #miss > 0 then
        if not wasOff then
            if enabled then
                logs.warn(string.format("%s 制作自动化：原料不足，已强制关断（机器 %s）",
                    constants.levelLabel(sub.level), binding.machineTextOf(sub.level, machine)))
            end
            local requiredItems = interface.requiredItems(method)
            if reconfigureIfMoved(machine, sub, requiredItems) then changed = true end
            local forceReason = "原料不足：" .. utils.joinLimited(miss, FORCE_REASON_WIDTH)
            state.write.produceSetSub(machine, { forceOff = true, forceReason = forceReason })
            changed = true
        end
    elseif wasOff then
        state.write.produceSetSub(machine, { forceOff = false, forceReason = nil })
        if enabled then
            logs.system(string.format("%s 制作自动化：原料已充足，解除强制关断（机器 %s）",
                constants.levelLabel(sub.level), binding.machineTextOf(sub.level, machine)))
        end
        changed = true
    end
    return changed
end

--- T1 巡检入口；forceLevel 非 nil 时只巡该级
function patrol.run(forceLevel)
    local changed = false
    local online = binding.onlineSet()
    local hostActive = state.read.plant(constants.HOST_LEVEL).active == true
    for machine, sub in pairs(state.read.produce().subs) do
        local method = produce.method(sub.level)
        if method and online[sub.transposer] then
            local entry = state.read.produceLevel(sub.level)
            local shouldScan = (forceLevel == sub.level)
                or (forceLevel == nil and (sub.sides == nil
                    or (hostActive and entry.enabled == true)))
            if shouldScan then
                if not sub.sides then
                    changed = configure(machine, sub, method, changed)
                else
                    changed = checkMachine(machine, sub, method, changed)
                end
            end
        end
    end
    return changed
end

return patrol
