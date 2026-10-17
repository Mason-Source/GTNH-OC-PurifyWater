--------------------------------------------------------------------------------
-- backend/app/produce.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化用例：绑定（机器 ↔ 转运器）/ 解绑 / 取消、侧位自动配置与落盘、原料巡检、就绪性刷新、开关、
--   周期投料（T3 边沿检测 -> 任务单 -> 每拍限流执行；原料由巡检维护的强制开关统一判定）
-- 【不做什么】不碰组件（走 hardware/*）、不写盘（走 store/*）、不判规则本身（domain/produce）
-- 【依赖】shared/*、core/scheduler、backend/domain/produce、backend/hardware/*、backend/store/*
-- 【被谁用】backend/jobs（T2s 读盘 + T1 刷新 + T8 任务）、backend/api（读取与命令）
--
-- 【绑定流程】配置页「制作自动化」面板选机器 -> beginBind -> 进入"绑定中"：
--   只认"点绑定之后新出现（不在开始快照里、且未绑给任何机器）"的转运器。
--   解绑后地址立即清空，再点绑定不会自动绑回旧值；先放好的转运器请拆下重放。
--   目标面 / 来源面由运行时自动配置（原料巡检负责配置与异常重配），配置成功后写入绑定表。
-- 【判据】运行期拦截（blocked）= 未就绪（绑定齐 + 在网）或原料巡检维护的强制关断；
--   开闸（点[开]）额外要求"侧位已自动配置"且"未被强制关断"（运行期侧位重配不会关停在跑的级）。
--------------------------------------------------------------------------------

local computer       = require("computer")
local CONFIG         = require("shared.config")
local constants      = require("shared.constants")
local logs           = require("shared.logs")
local state          = require("shared.state")
local utils          = require("shared.utils")

local scheduler      = require("core.scheduler")

local produce        = require("backend.domain.produce")

local device         = require("backend.hardware.device")
local machines       = require("backend.hardware.machines")
local probes         = require("backend.hardware.probes")
local transposer     = require("backend.hardware.transposer")

local produce_table  = require("backend.store.produce")
local produce_config = require("backend.store.produce_config")

local produceApp     = {}

-- 绑定提交失败的日志去重（同一原因只打一次，不刷屏）
local bindFailText   = nil

--------------------------------------------------------------------------------
-- 内部零件
--------------------------------------------------------------------------------

--- 绑定排序（先级后机器）
-- @param a table
-- @param b table
-- @return boolean
local function bindLess(a, b)
    if a.level ~= b.level then return a.level < b.level end
    return tostring(a.machine) < tostring(b.machine)
end

--- 机器显示文本：优先坐标（机器不写地址写坐标）；坐标不可用退回短地址
-- @param level number
-- @param address string
-- @return string
local function machineTextOf(level, address)
    for _, m in ipairs(machines.of(level)) do
        if m.address == address then
            if type(m.x) == "number" and type(m.y) == "number" and type(m.z) == "number" then
                return string.format("(%d,%d,%d)", m.x, m.y, m.z)
            end
            break
        end
    end
    return "无坐标(" .. utils.shortAddress(address) .. ")"
end

--- 从绑定表找某台机器的绑定
-- @param machine string
-- @return table|nil
local function bindOf(machine)
    for _, b in ipairs(state.read.produce().binds) do
        if b.machine == machine then return b end
    end
    return nil
end

--- 某转运器是否已绑给任何机器
-- @param address string
-- @return boolean
local function transposerBound(address)
    for _, b in ipairs(state.read.produce().binds) do
        if b.transposer == address then return true end
    end
    return false
end

--- 已绑定转运器的在线表（T1 每轮 / 绑定变更时刷新；只探测已绑地址）
-- @return table { [转运器地址] = true/false }
local function onlineSet()
    return state.read.produce().online
end

--- 只探测"已绑定"的转运器还在不在（component.type 单点查询，不枚举全部转运器）
-- 掉线 / 恢复各出一行日志（边沿；换件后的首个读数不算"恢复"）。
local function refreshOnline()
    local map = {}
    local old = state.read.produce().online
    for _, b in ipairs(state.read.produce().binds) do
        local now = device.isTransposerOnline(b.transposer)
        if now then
            local rate = transposer.rate(b.transposer)
            state.write.produceSetSub(b.machine, { rate = rate })
        else
            state.write.produceSetSub(b.machine, { rate = nil })
        end
        local was = old[b.transposer]
        if was ~= nil and was ~= now then
            if now then
                logs.system(string.format("%s 制作自动化：转运器 %s… 已恢复在线",
                    constants.levelLabel(b.level), utils.shortAddress(b.transposer)))
            else
                logs.warn(string.format("%s 制作自动化：转运器 %s… 掉线（机器 %s）",
                    constants.levelLabel(b.level), utils.shortAddress(b.transposer),
                    machineTextOf(b.level, b.machine)))
            end
        end
        map[b.transposer] = now
    end
    state.write.produceSetOnlineAll(map)
end

--- 某级机器集合（注册表）
-- @param level number
-- @return table { [地址] = true }
local function machineSetOf(level)
    local out = {}
    for _, m in ipairs(machines.of(level)) do out[m.address] = true end
    return out
end


--- 取 T3 最近一次观测到的单台机器事实（含 switch / active）
-- 周期规划与任务启动都复用它，避免在周期边沿再做一批 component 调用。
-- @param level number
-- @param machine string
-- @return table|nil
local function observedMachine(level, machine)
    for _, fact in ipairs(state.read.plant(level).machines or {}) do
        if fact.address == machine then return fact end
    end
    return nil
end

--- 该级每台机器一条的检查输入（含绑定表里已不在注册表的机器）
-- @param level number
-- @return table
local function unitsOf(level)
    local online = onlineSet()
    local out, seen = {}, {}
    for _, m in ipairs(machines.of(level)) do
        seen[m.address] = true
        local b = bindOf(m.address)
        local sub = b and state.read.produce().subs[b.machine] or nil
        out[#out + 1] = {
            machine    = m.address,
            transposer = b and b.transposer or nil,
            online     = (b and online[b.transposer]) or nil,
            rate       = (b and online[b.transposer] and sub) and sub.rate or nil
        }
    end
    for _, b in ipairs(state.read.produce().binds) do
        if b.level == level and not seen[b.machine] then
            out[#out + 1] = {
                machine    = b.machine,
                transposer = b.transposer,
                online     = online[b.transposer] or nil,
                rate       = (online[b.transposer] and state.read.produce().subs[b.machine]) and state.read.produce().subs[b.machine].rate or nil
            }
        end
    end
    return out
end

--- 该级被运行期拦住的子系统原因（强制关断等）
-- @param level number
-- @return string|nil
local function blockedReasonOf(level)
    for _, sub in pairs(state.read.produce().subs) do
        if sub.level == level and sub.forceOff == true then
            return sub.forceReason or "原料不足"
        end
    end
    return nil
end

--- 展示状态（便宜判定现算）：invalid / off / blocked / ok
-- @param level number
-- @return string
-- @return string|nil
local function stateOf(level)
    local entry = state.read.produceLevel(level)
    if entry.valid ~= true then return "invalid", entry.validReason or "未就绪" end
    if entry.enabled ~= true then return "off", nil end
    local blocked = blockedReasonOf(level)
    if blocked then return "blocked", blocked end
    return "ok", nil
end

--- 写回某台机器的侧位（nil = 清除）；target 使用机器地址作为键
-- @param machine string
-- @param sides table|nil
-- @param layout string|nil
-- @return boolean ok
-- @return string|nil 失败原因
local function saveSideConfig(machine, sides, layout)
    local binds = {}
    local found = false
    for _, b in ipairs(state.read.produce().binds) do
        local copy = {
            level      = b.level,
            machine    = b.machine,
            transposer = b.transposer,
            sides      = b.sides,
            layout     = b.layout
        }
        if b.machine == machine then
            copy.sides, copy.layout = sides, layout
            found = true
        end
        binds[#binds + 1] = copy
    end
    if not found then return false, "该机器未绑定" end

    local ok, err = produce_table.save(binds)
    if not ok then
        logs.warn("制作自动化侧位落盘失败：" .. tostring(err))
        return false, tostring(err)
    end
    state.write.produceSetBinds(binds)
    return true, nil
end

--- 按绑定表重建子系统表（同机器保留运行期记录）
local function applyBinds()
    local old  = state.read.produce().subs
    local subs = {}
    for _, b in ipairs(state.read.produce().binds) do
        local keep = old[b.machine] or {}
        local same = (keep.transposer == b.transposer) -- 换件要重新配置侧位
        local sides, layout
        if keep.transposer == nil then
            -- 启动首读：使用落盘侧位，不因重启主动扫描
            sides, layout = b.sides, b.layout
        elseif same then
            sides  = keep.sides or b.sides
            layout = keep.layout or b.layout
        end
        subs[b.machine] = {
            level       = b.level,
            transposer  = b.transposer,
            rate        = same and keep.rate or nil,      -- 转运速率（T1 刷新）
            cycleSeq    = keep.cycleSeq or 0,
            sides       = sides,
            sideTarget  = sides and sides.target or nil,  -- 输出面粘住（重配置只重算输入侧）
            itemTarget  = sides and sides.itemTarget or nil, -- 物品输出面粘住
            sideFail    = same and keep.sideFail or nil,
            layout      = layout,                          -- 容器方位签名（原料不足时判断"动过没"）
            forceOff    = same and keep.forceOff or nil,   -- 原料巡检维护的强制开关
            forceReason = same and keep.forceReason or nil
        }
    end
    state.write.produceSetSubs(subs)
end

--------------------------------------------------------------------------------
-- 侧位自动配置（方法模块给"需要的全部流体"，本模块扫转运器周围的容器）
--------------------------------------------------------------------------------

--- 缺哪些必需流体（条目 = 字符串：单一；条目 = { label=, any={...} }：任一即可）
-- @param required table 方法模块给的流体要求
-- @param found table { [流体名] = true } 已找到的流体集合
-- @return table 缺失说明数组（人话，可直接进日志）
local function missingFluids(required, found)
    local miss = {}
    for _, item in ipairs(required) do
        if type(item) == "table" then
            local hit = false
            for _, name in ipairs(item.any or {}) do
                if found[name] then
                    hit = true
                    break
                end
            end
            if not hit then miss[#miss + 1] = tostring(item.label or "?") end
        elseif not found[item] then
            miss[#miss + 1] = tostring(item)
        end
    end
    return miss
end

--- 物品条目是否相同（name + damage）
local function sameItem(a, b)
    return a ~= nil and b ~= nil
        and a.name == b.name
        and (tonumber(a.damage) or 0) == (tonumber(b.damage) or 0)
end

--- 某个面的容器签名（流体名 + 物品 name:damage；不看量）
local function signatureOf(side, entry)
    local fluidNames, itemNames = {}, {}
    for _, item in ipairs(entry.fluids or {}) do
        if item.fluid then fluidNames[#fluidNames + 1] = item.fluid end
    end
    for _, item in ipairs(entry.items or {}) do
        itemNames[#itemNames + 1] = string.format("%s:%d", tostring(item.name), tonumber(item.damage) or 0)
    end
    table.sort(fluidNames)
    table.sort(itemNames)
    return string.format("%d:F[%s]I[%s]", side, table.concat(fluidNames, ","), table.concat(itemNames, ","))
end

--- 扫描六个面（流体罐 + 物品库存）
local function scanSides(address, needItems)
    local out = {}
    for side = 0, 5 do
        local fluids   = transposer.containers(address, side)
        -- 不需要物品的方法（T3/T7）不读库存：getStackInSlot 逐槽调用很贵，
        -- 且这些级不会把物品容器纳入侧位判定。
        local itemSize = needItems and transposer.inventorySize(address, side) or nil
        if fluids or itemSize then
            local items = itemSize and transposer.items(address, side, itemSize) or nil
            local hasFluid = false
            for _, item in ipairs(fluids or {}) do
                if item.fluid then hasFluid = true; break end
            end
            out[side] = {
                fluids     = fluids,
                items      = items or {},
                itemSize   = itemSize or 0,
                hasFluid   = hasFluid,
                hasItems   = items ~= nil and #items > 0,
                emptyFluid = fluids ~= nil and not hasFluid
            }
        end
    end
    return out
end

--- 尝试配置：流体（空容器=输出、凑齐全部流体=输入）+ 物品（物品源/物品输出侧）
-- @param machine string
-- @param sub table
-- @param requiredFluids table|nil 流体注册名 / any 条目
-- @param requiredItems table|nil 物品条目 {name, damage, label}
-- @return boolean ok
-- @return string|nil 失败原因
-- @return string 扫描明细
-- @return table|nil 成功时的 sides
local function tryConfigSides(machine, sub, requiredFluids, requiredItems)
    local preferred     = sub.sideTarget
    local preferredItem = sub.itemTarget
    local target, emptyCount, emptySide, sources, found = nil, 0, nil, {}, {}
    local itemTarget, itemSources, itemEmptyCount, itemEmptySide = nil, {}, 0, nil
    local needItems = requiredItems ~= nil and #requiredItems > 0
    local info = scanSides(sub.transposer, needItems)
    local scan, sig = {}, {}

    for side = 0, 5 do
        local entry = info[side]
        if entry then
            sig[#sig + 1] = signatureOf(side, entry)

            local fluidNames = {}
            for _, item in ipairs(entry.fluids or {}) do
                if item.fluid then fluidNames[#fluidNames + 1] = item.fluid end
            end
            table.sort(fluidNames)
            local itemNames = {}
            for _, item in ipairs(entry.items) do
                itemNames[#itemNames + 1] = string.format("%s#%d", tostring(item.name), tonumber(item.damage) or 0)
            end
            table.sort(itemNames)
            scan[#scan + 1] = string.format("%s=F[%s]I[%s]", utils.sideLabel(side),
                (#fluidNames > 0) and table.concat(fluidNames, ",") or "空",
                (#itemNames > 0) and table.concat(itemNames, ",") or "空")

            -- 流体分类（有罐的面才参与）
            if entry.fluids then
                if preferred ~= nil and side == preferred then
                    target = side
                elseif entry.hasFluid then
                    sources[#sources + 1] = side
                    for _, name in ipairs(fluidNames) do found[name] = true end
                else
                    emptyCount = emptyCount + 1
                    emptySide  = emptySide or side
                end
            end

            -- 物品分类（有物品库存的面才参与）
            if requiredItems and #requiredItems > 0 and entry.itemSize > 0 then
                local contains = false
                for _, item in ipairs(entry.items) do
                    for _, req in ipairs(requiredItems) do
                        if sameItem(item, req) then contains = true; break end
                    end
                    if contains then break end
                end
                if preferredItem ~= nil and side == preferredItem then
                    itemTarget = side
                elseif contains then
                    itemSources[#itemSources + 1] = side
                else
                    itemEmptyCount = itemEmptyCount + 1
                    itemEmptySide  = itemEmptySide or side
                end
            end
        end
    end
    local detail = table.concat(scan, " ")

    -- 流体：输出侧 / 输入侧
    if requiredFluids and #requiredFluids > 0 then
        if target == nil then
            if emptyCount == 0 then
                return false, "找不到空容器（流体输出侧）", detail, nil
            end
            if emptyCount > 1 then
                return false, "有多个空容器，无法确定流体输出侧", detail, nil
            end
            target = emptySide
        end
        local miss = missingFluids(requiredFluids, found)
        if #miss > 0 then
            return false, "输入侧缺流体：" .. table.concat(miss, "、"), detail, nil
        end
    end

    -- 物品：输出侧 / 输入侧
    if requiredItems and #requiredItems > 0 then
        if itemTarget == nil then
            if itemEmptyCount == 0 then
                return false, "找不到物品输出侧（需要物品存储空间）", detail, nil
            end
            if itemEmptyCount > 1 then
                return false, "有多个物品输出侧，无法确定", detail, nil
            end
            itemTarget = itemEmptySide
        end
        local missItems = {}
        for _, req in ipairs(requiredItems) do
            local hit = false
            for _, side in ipairs(itemSources) do
                for _, item in ipairs(info[side] and info[side].items or {}) do
                    if sameItem(item, req) then hit = true; break end
                end
                if hit then break end
            end
            if not hit then missItems[#missItems + 1] = tostring(req.label or req.name) end
        end
        if #missItems > 0 then
            return false, "输入侧缺物品：" .. table.concat(missItems, "、"), detail, nil
        end
    end

    local sides = {
        target      = target,
        sources     = sources,
        itemTarget  = itemTarget,
        itemSources = itemSources
    }
    local layout = table.concat(sig, "|")
    state.write.produceSetSub(machine, {
        sides      = sides,
        sideTarget = target,
        itemTarget = itemTarget,
        sideFail   = nil,
        layout     = layout
    })
    -- 自动配置成功后立即落盘；重启时直接复用，不因开机重新扫描。
    saveSideConfig(machine, sides, layout)
    return true, nil, detail, sides
end

--- 容器方位签名（流体 + 物品；用于原料不足时的"容器动过没"判断）
-- @param sub table
-- @return string
local function layoutSignature(sub, needItems)
    local info = scanSides(sub.transposer, needItems)
    local parts = {}
    for side, entry in pairs(info) do
        parts[#parts + 1] = signatureOf(side, entry)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

--- "任意一款"需求按巡检结果解析（都没有就报第一款）
-- @param found table { [流体名] = 最大余量 }
-- @param anyList table 候选流体数组
-- @return string
local function resolveAnyFound(found, anyList)
    local picked, best = nil, 0
    for _, fluid in ipairs(anyList or {}) do
        local amount = found[fluid] or 0
        if amount > best then
            picked, best = fluid, amount
        end
    end
    return picked or (anyList and anyList[1]) or "?"
end

--- 原料巡检（T1，10s）：侧位配置 / 流体+物品余量检查 + 维护强制开关
-- 原料不足时做一次性"容器方位变化检测"：方位变了 -> 触发重配（sides 清空，下轮重扫）。
-- @return boolean 侧位配置或强制开关有变化（供 produce_changed 事件）
function produceApp.patrol()
    local changed = false
    local online  = onlineSet()
    for machine, sub in pairs(state.read.produce().subs) do
        local method = produce.method(sub.level)
        if method and online[sub.transposer] then
            local requiredFluids = method.requiredFluids and method.requiredFluids() or nil
            local requiredItems  = method.requiredItems and method.requiredItems() or nil

            if not sub.sides then
                local hasFluids = requiredFluids and #requiredFluids > 0
                local hasItems  = requiredItems and #requiredItems > 0
                if hasFluids or hasItems then
                    local ok, reason, detail, sides = tryConfigSides(machine, sub, requiredFluids, requiredItems)
                    if ok and sides then
                        local names = {}
                        for _, side in ipairs(sides.sources or {}) do
                            names[#names + 1] = utils.sideLabel(side)
                        end
                        local itemText = ""
                        if sides.itemTarget then
                            local itemNames = {}
                            for _, side in ipairs(sides.itemSources or {}) do
                                itemNames[#itemNames + 1] = utils.sideLabel(side)
                            end
                            itemText = string.format("；物品输出=%s，物品输入=%s",
                                utils.sideLabel(sides.itemTarget),
                                (#itemNames > 0) and table.concat(itemNames, "/") or "-")
                        end
                        logs.debug(string.format("%s 制作自动化：侧位配置完成（机器 %s）：流体输出=%s，流体输入=%s%s",
                            constants.levelLabel(sub.level), machineTextOf(sub.level, machine),
                            sides.target and utils.sideLabel(sides.target) or "-",
                            table.concat(names, "/"), itemText))
                        changed = true
                    else
                        local prev = sub.sideFail
                        state.write.produceSetSub(machine, { sideFail = reason })
                        if prev ~= reason then
                            logs.debug(string.format("%s 制作自动化：侧位配置失败——%s（机器 %s）｜扫描 %s",
                                constants.levelLabel(sub.level), tostring(reason),
                                machineTextOf(sub.level, machine), tostring(detail or "-")))
                        end
                    end
                end
            else
                local stock
                if method.patrolByNeed and method.patrolByNeed() then
                    local demand = method.need(probes.sensorLines(machine))
                    if demand == nil then
                        stock = nil -- pH 未初始化/读不到：本轮不判原料
                    else
                        stock = demand -- 按当前需求检查（空表 = 已达标）
                    end
                else
                    stock = method.stockRequirements and method.stockRequirements() or nil
                end
                if stock ~= nil then
                    local enabled = state.read.produceLevel(sub.level).enabled == true
                    local needFluid, needItem = false, false
                    for _, need in ipairs(stock) do
                        if need.item then needItem = true else needFluid = true end
                    end

                    -- 只读本轮真正需要的介质：T4 在 pH 已达标时不再逐槽扫描物品源，
                    -- 避免每 10 秒固定触发一次 9 槽 item 读取。
                    local found = {}
                    if needFluid then
                        for _, side in ipairs(sub.sides.sources or {}) do
                            for _, item in ipairs(transposer.containers(sub.transposer, side) or {}) do
                                if item.fluid and (not found[item.fluid] or (item.amount or 0) > found[item.fluid]) then
                                    found[item.fluid] = item.amount or 0
                                end
                            end
                        end
                    end

                    -- 源侧物品：name:damage -> 总数量
                    local foundItems = {}
                    if needItem then
                        for _, side in ipairs(sub.sides.itemSources or {}) do
                            for _, item in ipairs(transposer.items(sub.transposer, side) or {}) do
                                local key = item.name .. ":" .. item.damage
                                foundItems[key] = (foundItems[key] or 0) + item.size
                            end
                        end
                    end

                    local miss = {}
                    for _, need in ipairs(stock) do
                        if need.item then
                            local key = need.item.name .. ":" .. need.item.damage
                            local have = foundItems[key] or 0
                            if have < need.amount then
                                miss[#miss + 1] = string.format("%s %d/%d个",
                                    tostring(need.label or need.item.label), have, need.amount)
                            end
                        else
                            local fluid = need.fluid or resolveAnyFound(found, need.any)
                            local have  = fluid and (found[fluid] or 0) or 0
                            if have < need.amount then
                                miss[#miss + 1] = string.format("%s %d/%dL",
                                    tostring(need.label or fluid), have, need.amount)
                            end
                        end
                    end

                    local wasOff = sub.forceOff == true
                    if #miss > 0 then
                        if not wasOff then
                            if enabled then
                                logs.warn(string.format("%s 制作自动化：原料不足，已强制关断（机器 %s）",
                                    constants.levelLabel(sub.level), machineTextOf(sub.level, machine)))
                            end
                            logs.debug(string.format("%s 制作自动化：原料不足明细——%s",
                                constants.levelLabel(sub.level), table.concat(miss, "、")))
                            -- 一次性：容器方位变化检测（变了 -> 重配侧位）
                            local sig = layoutSignature(sub, requiredItems ~= nil and #requiredItems > 0)
                            if sub.layout ~= nil and sig ~= sub.layout then
                                produceApp.reconfigure(machine, "容器方位变化")
                            end
                            state.write.produceSetSub(machine, { forceOff = true, forceReason = "原料不足" })
                            changed = true
                        end
                    elseif wasOff then
                        state.write.produceSetSub(machine, { forceOff = false, forceReason = nil })
                        if enabled then
                            logs.system(string.format("%s 制作自动化：原料已充足，解除强制关断（机器 %s）",
                                constants.levelLabel(sub.level), machineTextOf(sub.level, machine)))
                        end
                        changed = true
                    end
                end
            end
        end
    end
    return changed
end


--- 重算全部等级的就绪性；返回是否有等级的就绪性变化
-- @return boolean changed
local function refreshAll()
    local changed = false
    for level = 1, constants.LEVEL_COUNT do
        local prevValid = state.read.produceLevel(level).valid == true
        local method = produce.method(level)
        local ok, reason = produce.check(level, unitsOf(level), {
            machines = machineSetOf(level),
            minRate  = (method and method.minTransferRate and method.minTransferRate()) or nil
        })
        state.write.produceSetLevel(level, { valid = ok, validReason = reason or "" })
        if prevValid ~= ok then
            changed = true
            logs.debug(string.format("%s 制作自动化%s：%s", constants.levelLabel(level),
                ok and "已就绪" or "未就绪", tostring(reason or "-")))
        end
    end
    return changed
end

--- 发事件（只在有变化时由调用方发）
-- @param reason string
local function notify(reason)
    scheduler.emit("produce_changed", { reason = reason })
end

--- 落一条绑定（先写盘成功再改内存）
-- @param level number
-- @param machine string
-- @param transposerAddress string
-- @param message string 成功日志
-- @return boolean ok
-- @return string 说明
local function commitBind(level, machine, transposerAddress, message)
    local binds = {}
    for _, b in ipairs(state.read.produce().binds) do
        if b.machine ~= machine then binds[#binds + 1] = b end   -- 重绑：整条替换
    end
    binds[#binds + 1] = { level = level, machine = machine, transposer = transposerAddress }
    table.sort(binds, bindLess)

    local ok, err = produce_table.save(binds)
    if not ok then return false, "写绑定表失败（data/produce.txt）：" .. tostring(err) end

    state.write.produceSetBinds(binds)
    state.write.produceSetBinding(nil)
    applyBinds()
    refreshOnline()
    logs.system(message)
    refreshAll()
    notify("绑定：" .. tostring(machine))
    return true, ""
end

--------------------------------------------------------------------------------
-- 对外：读盘（T2s）与刷新（T1）
--------------------------------------------------------------------------------

--- 启动 / 设置对账：读开关与绑定表，重建子系统并重算就绪性
-- @param snapshot table|nil settings.load() 的结果（不传自己读）
-- @return boolean changed
-- @return string 说明
function produceApp.reload(snapshot)
    local changedSwitch, whySwitch = produce_config.load(snapshot)

    local entries, problems = produce_table.load()
    if #problems > 0 then
        logs.warn(string.format("制作自动化绑定表：%s%s", tostring(problems[1]),
            (#problems > 1) and ("（共 " .. #problems .. " 条问题）") or ""))
    end

    local changedBinds = false
    local old = state.read.produce().binds
    if #old ~= #entries then
        changedBinds = true
    else
        for index = 1, #entries do
            local a, b = old[index], entries[index]
            if a.level ~= b.level or a.machine ~= b.machine or a.transposer ~= b.transposer then
                changedBinds = true
                break
            end
        end
    end

    state.write.produceSetBinds(entries)
    applyBinds()
    refreshOnline()
    local changedState = refreshAll()

    local changed = changedSwitch or changedBinds or changedState
    return changed, changed and "制作自动化配置已更新" or tostring(whySwitch or "制作自动化配置未变化")
end

--- T1 每轮调用：只探测已绑定件的在线状态 + 重算就绪性（不枚举全部转运器）
-- @return boolean changed
function produceApp.refresh()
    refreshOnline()
    return refreshAll()
end

--------------------------------------------------------------------------------
-- 对外：绑定 / 解绑 / 取消
--------------------------------------------------------------------------------

--- 开始绑定某台机器
-- @param level number
-- @param machine string 机器组件地址
-- @return boolean ok
-- @return string 说明（失败原因；成功留空——日志由本模块写）
function produceApp.beginBind(level, machine)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if type(machine) ~= "string" or machine == "" then return false, "机器无效" end
    if state.read.produce().binding then return false, "已有正在进行的绑定，请先取消" end
    refreshOnline() -- "已绑在线"用最新状态判断
    local existing = bindOf(machine)
    if existing and onlineSet()[existing.transposer] then
        return false, "该机器已绑定且转运器在线（先解绑再重绑）"
    end
    if not machineSetOf(level)[machine] then
        return false, "机器不在该级注册表（先刷新扫描再试）"
    end

    local label = constants.levelLabel(level)
    local text  = machineTextOf(level, machine)

    local snapshot, unboundCount = {}, 0
    for _, address in ipairs(device.scanTransposers()) do
        snapshot[address] = true
        if not transposerBound(address) then unboundCount = unboundCount + 1 end
    end

    state.write.produceSetBinding({ level = level, machine = machine, snapshot = snapshot })
    logs.system(string.format("%s 制作自动化：开始绑定（机器 %s）——请放下转运器并接入网络", label, text))
    if unboundCount > 0 then
        logs.warn(string.format("%s 制作自动化：网络有 %d 个未绑定转运器", label, unboundCount))
    end
    notify("开始绑定：" .. label)
    return true, ""
end

--- 取消"绑定中"
-- @return boolean ok
-- @return string 说明
function produceApp.cancelBind()
    local binding = state.read.produce().binding
    if not binding then return false, "当前没有正在进行的绑定" end

    state.write.produceSetBinding(nil)
    logs.system(string.format("%s 制作自动化：已取消绑定", constants.levelLabel(binding.level)))
    notify("取消绑定")
    return true, ""
end

--- 解绑某台机器
-- @param machine string 机器组件地址
-- @return boolean ok
-- @return string 说明
function produceApp.unbind(machine)
    local b = bindOf(machine)
    if not b then return false, "该机器未绑定" end
    if type(machine) ~= "string" then return false, "机器无效" end

    local binding = state.read.produce().binding
    if binding and binding.machine == machine then state.write.produceSetBinding(nil) end

    local binds = {}
    for _, item in ipairs(state.read.produce().binds) do
        if item.machine ~= machine then binds[#binds + 1] = item end
    end

    local ok, err = produce_table.save(binds)
    if not ok then return false, "写绑定表失败（data/produce.txt）：" .. tostring(err) end

    state.write.produceSetBinds(binds)
    applyBinds()
    refreshOnline()
    logs.system(string.format("%s 制作自动化：已解绑 %s…（机器 %s）",
        constants.levelLabel(b.level), utils.shortAddress(b.transposer), machineTextOf(b.level, machine)))
    refreshAll()
    notify("解绑：" .. tostring(machine))
    return true, ""
end

--- 让某台机器重新走一次"侧位自动配置"（原料巡检发现容器方位变化时调用）
-- 输出面 sideTarget 粘住：只重算输入侧，机器仓已有流体也不会被误判成输入容器。
-- @param machine string 机器组件地址
-- @param why string 触发原因（进日志）
-- @return boolean ok
-- @return string 说明
function produceApp.reconfigure(machine, why)
    local sub = state.read.produce().subs[machine]
    if not sub then return false, "该机器没有子系统（可能未绑定）" end

    state.write.produceClearSides(machine)
    saveSideConfig(machine, nil, nil)
    if why then
        logs.debug(string.format("%s 制作自动化：%s，触发重新配置（机器 %s）",
            constants.levelLabel(sub.level), tostring(why), machineTextOf(sub.level, machine)))
    end
    return true, ""
end

--------------------------------------------------------------------------------
-- 对外：开关（就绪才允许开）
--------------------------------------------------------------------------------

--- 用户开关某一级的制作自动化（api.exec("level_produce_set") 的唯一实现）
-- 开的要求：绑定齐 + 转运器在网 + 侧位已自动配置；关任何时候都允许。
-- 注意：侧位是否配好只卡这里（开闸）；运行期 blocked 不看它，重配不会关停在跑的级。
-- @param level number|string
-- @param enabled boolean
-- @return boolean ok
-- @return string 说明
function produceApp.setEnabled(level, enabled)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if type(enabled) ~= "boolean" then return false, "开关值无效" end

    local label = constants.levelLabel(level)
    if enabled == true then
        refreshOnline()
        local method = produce.method(level)
        local ok, reason = produce.check(level, unitsOf(level), {
            machines = machineSetOf(level),
            minRate  = (method and method.minTransferRate and method.minTransferRate()) or nil
        })
        state.write.produceSetLevel(level, { valid = ok, validReason = reason or "" })
        if not ok then
            return false, string.format("%s 制作自动化未就绪：%s", label, tostring(reason))
        end
        -- 开闸额外要求"侧位已自动配置好"（运行期重配不走这里）
        local pending = nil
        for _, b in ipairs(state.read.produce().binds) do
            if b.level == level then
                local sub = state.read.produce().subs[b.machine]
                if not (sub and sub.sides) then
                    pending = b.machine
                    break
                end
            end
        end
        if pending then
            return false, string.format("%s 制作自动化未就绪：侧位尚未自动配置（机器 %s）",
                label, machineTextOf(level, pending))
        end
        -- 原料不足（T1 巡检维护的强制开关）：不允许开场
        for _, b in ipairs(state.read.produce().binds) do
            if b.level == level then
                local sub = state.read.produce().subs[b.machine]
                if sub and sub.forceOff == true then
                    return false, string.format("%s 制作自动化原料不足：%s（机器 %s）",
                        label, tostring(sub.forceReason or "原料不足"), machineTextOf(level, b.machine))
                end
            end
        end
        local saved, err = produce_config.set(level, true)
        if not saved then return false, "写配置失败（settings.txt）：" .. tostring(err) end
        logs.system(string.format("%s 制作自动化：已开启（%d 台机器）", label, #unitsOf(level)))
        notify("开关：" .. label .. " 开")
        return true, ""
    end

    local saved, err = produce_config.set(level, false)
    if not saved then return false, "写配置失败（settings.txt）：" .. tostring(err) end
    logs.system(string.format("%s 制作自动化：已关闭", label))
    notify("开关：" .. label .. " 关")
    return true, ""
end

--------------------------------------------------------------------------------
-- 对外：只读视图（界面唯一数据源）
--------------------------------------------------------------------------------

--- 制作自动化只读视图
-- @return table { binding = {level, machine, text}|nil, levels = { [n] = {...} } }
function produceApp.read()
    local online = onlineSet()
    local levels = {}
    for level = 1, constants.LEVEL_COUNT do
        local entry      = state.read.produceLevel(level)
        local st, reason = stateOf(level)
        local method     = produce.method(level)
        local applicable = (method and method.requiredFluids) and true or false

        local list, bound, onlineCount, configured = {}, 0, 0, 0
        for _, m in ipairs(machines.of(level)) do
            local b         = bindOf(m.address)
            local sub       = b and state.read.produce().subs[b.machine] or nil
            local subOnline = (b and online[b.transposer]) or nil
            -- 每台机器的侧位状态：- 不适用 / auto 自动配置中 / ok 配置就绪；sideFail = 失败原因（界面显示）
            -- 未绑定 / 转运器不在网 -> 与未绑定一样显示 -（也不计进 configured）
            local sideState = "-"
            if b and applicable and subOnline then
                sideState = (sub and sub.sides) and "ok" or "auto"
                if sub and sub.sides then configured = configured + 1 end
            end
            list[#list + 1] = {
                address   = m.address,
                text      = machineTextOf(level, m.address),
                bound     = b and b.transposer or nil,
                online    = subOnline,
                sideState = sideState,
                sideFail  = (subOnline and sub) and sub.sideFail or nil,
                rate      = subOnline and sub and sub.rate or nil
            }
            if b then bound = bound + 1 end
            if subOnline then onlineCount = onlineCount + 1 end
        end

        levels[level] = {
            enabled    = entry.enabled == true,
            state      = st,
            reason     = reason,
            ready      = entry.valid == true,
            count      = #list,
            bound      = bound,
            online     = onlineCount,
            configured = configured, -- 转运器已绑定且侧位自动配置完成的机器数
            machines   = list
        }
    end

    local b = state.read.produce().binding
    local binding = nil
    if b then
        binding = { level = b.level, machine = b.machine, text = machineTextOf(b.level, b.machine) }
    end
    return { binding = binding, levels = levels }
end

--------------------------------------------------------------------------------
-- 周期投料：周期事件 -> 机器队列 -> 每拍一笔（chunk）执行
--------------------------------------------------------------------------------
-- 【驱动】T3 周期边界 -> onCycleProgress -> seq++ -> produce_cycle -> onCycleStarted 入队。
-- 【安全调用】单笔 count ≤ floor(rate * CHUNK_RATIO)：OC 的 transferFluid 只在
--   moved/rate - 0.05 > 0 时 context.pause；这个上限保证永不触发 pause。
-- 【节奏】produce_feed 任务每 CHUNK 拍取一笔（0.05s ≈ 一个 game tick）；
--   多流体按队列顺序逐笔；一台机器做完再下一台；空队列零开销。
-- 【单台】输出侧残留 -> 强制开关 -> 控制信号需求 -> 速率/最低速率 -> 逐笔转运；
--   失败给直接原因（警告），本周期终止该机器。

local machineQueue = {} -- 本周期规划表：{ {machine=, seq=}, ... }（只规划一次，不重试）
local activeJob    = nil -- 当前机器：{ machine, seq, level, items, index, chunk, done }

--- 输入侧找某流体余量最大的那罐
-- @param sub table 子系统
-- @param fluid string 流体注册名
-- @return number|nil 侧
-- @return number|nil 罐（1 基）
-- @return number 余量（没找到 = 0）
local function findSource(sub, fluid)
    local side, tank, amount = nil, nil, 0
    for _, candidate in ipairs((sub.sides and sub.sides.sources) or {}) do
        for _, item in ipairs(transposer.containers(sub.transposer, candidate) or {}) do
            if item.fluid == fluid and (item.amount or 0) > amount then
                side, tank, amount = candidate, item.tank, item.amount
            end
        end
    end
    return side, tank, amount
end

--- 粗胚这类"任意一款"需求：按输入侧实有的那款解析（都没有就报第一款的名字）
-- @param sub table
-- @param anyList table 候选流体数组
-- @return string
local function resolveAny(sub, anyList)
    local picked, pickedAmount = nil, 0
    for _, fluid in ipairs(anyList or {}) do
        local _, _, amount = findSource(sub, fluid)
        if amount > pickedAmount then
            picked, pickedAmount = fluid, amount
        end
    end
    return picked or (anyList and anyList[1]) or "?"
end

--- 周期进度比例（拿不到最大值返回 nil = 不拦）
-- @return number|nil
local function cycleRatio()
    local cycle = state.read.produce().cycle
    local progress, max = cycle.lastProgress, cycle.progressMax
    if type(progress) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
    return progress / max
end

--- 结束当前机器（本周期不再投；跨周期完成时记当前周期号）
-- @param reason string|nil 附加说明（debug）
local function finishJob(reason)
    if not activeJob then return end
    local job = activeJob
    activeJob = nil
    local seq = state.read.produce().cycle.seq or job.seq
    state.write.produceSetSub(job.machine, { cycleSeq = seq })
    if reason then
        logs.debug(string.format("%s 制作自动化：%s（机器 %s）",
            constants.levelLabel(job.level), tostring(reason), job.text))
    end
end

--- 放弃当前任务；侧位相关失败同时触发一次重配（下一轮 T1 重新扫描）
-- @param reason string
-- @param reconfig boolean|nil
local function failJob(reason, reconfig)
    local job = activeJob
    if not job then return end
    if reconfig then produceApp.reconfigure(job.machine, reason) end
    finishJob(reason)
end

--- 开始下一台机器：一次规划任务的前置检查 + 需求解析 + 速率/单笔上限
-- @param machine string
-- @param seq number
-- @return boolean 是否真的开始（false = 本周期已处理/放弃）
local function startJob(machine, seq)
    local sub = state.read.produce().subs[machine]
    if not sub or (sub.cycleSeq or 0) == seq then return false end
    local label  = constants.levelLabel(sub.level)
    local text   = machineTextOf(sub.level, machine)
    local method = produce.method(sub.level)

    -- 侧位配置是任务成立的前提；计划阶段已经过滤，这里再防一次运行中重配。
    -- 不做 1 秒重试：本周期放弃该机器，下一个 T0 周期重新规划。
    if not sub.sides then
        logs.debug(string.format("%s 制作自动化：侧位未配置，本周期放弃（机器 %s）", label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end

    -- 复用 T3 最近一次观测事实，不在任务启动时额外批量调用组件。
    -- 如果观测数据里机器已不在运行，则放弃本次任务，不做重试。
    local fact = observedMachine(sub.level, machine)
    if not fact or fact.switch ~= true or fact.active ~= true then
        logs.debug(string.format("%s 制作自动化：观测到的机器未开启/未运行，本周期放弃本次任务（机器 %s）",
            label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end

    -- 输出侧残留：上一批没消耗（流体目标 + 物品目标）-> 本周期放弃该任务
    local residue = nil
    if sub.sides.target then
        for _, item in ipairs(transposer.containers(sub.transposer, sub.sides.target) or {}) do
            if item.fluid then
                residue = item.fluid
                break
            end
        end
    end
    if not residue and sub.sides.itemTarget then
        local items = transposer.items(sub.transposer, sub.sides.itemTarget)
        if items and #items > 0 then
            residue = items[1].label or items[1].name
        end
    end
    if residue then
        logs.warn(string.format("%s 制作自动化：输出侧残留未消耗，本周期放弃本次任务（机器 %s）", label, text))
        logs.debug(string.format("%s 制作自动化：残留明细——%s（机器 %s）", label, tostring(residue), text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end

    -- 强制开关（原料巡检维护；这里只读）
    if sub.forceOff == true then
        logs.debug(string.format("%s 制作自动化：原料不足，本周期放弃（机器 %s）", label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end

    -- 控制信号 / 传感器 -> 需求
    local demand, why, signal = method.need(probes.sensorLines(machine))
    if not demand then
        logs.warn(string.format("%s 制作自动化：%s，本周期放弃本次任务（机器 %s）",
            label, tostring(why), text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end
    if #demand == 0 then
        logs.debug(string.format("%s 制作自动化：无需求，本周期不投（机器 %s，读数 %s）",
            label, text, tostring(signal)))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end

    -- 速率 / 最低速率 / 单笔上限（按该级流体步长取整）
    local rate = sub.rate
    if type(rate) ~= "number" then rate = transposer.rate(sub.transposer) end
    if type(rate) ~= "number" or rate <= 0 then
        logs.warn(string.format("%s 制作自动化：读不到转运速率（机器 %s）", label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end
    local minRate = method.minTransferRate and method.minTransferRate() or nil
    if minRate and rate < minRate then
        logs.warn(string.format("%s 制作自动化：转运器速度不足 %d < %d mB/s（机器 %s）",
            label, rate, minRate, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end
    local unit  = method.fluidUnit and method.fluidUnit() or 1
    local chunk = math.floor(rate * (tonumber(CONFIG.PRODUCE.CHUNK_RATIO) or 0.05))
    chunk = chunk - chunk % unit
    if chunk < unit then
        logs.warn(string.format("%s 制作自动化：转运速率过低，无法拆分（机器 %s）", label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end

    -- 需求（流体 / 物品）
    local items = {}
    for _, need in ipairs(demand) do
        if need.item then
            items[#items + 1] = {
                kind = "item", item = need.item, label = need.label or need.item.label,
                amount = need.amount, remaining = need.amount
            }
        else
            local fluid = need.fluid or resolveAny(sub, need.any)
            items[#items + 1] = {
                kind = "fluid", fluid = fluid, label = need.label,
                amount = need.amount, remaining = need.amount
            }
        end
    end
    activeJob = {
        machine = machine, seq = seq, level = sub.level, text = text,
        items = items, index = 1, chunk = chunk, done = {}
    }
    return true
end

--- 找物品源槽（name + damage 匹配，返回 1 基槽）
-- @param sub table
-- @param required table {name, damage}
-- @return number|nil 侧
-- @return number|nil 槽
-- @return number 堆叠数
local function findItemSource(sub, required)
    for _, side in ipairs(sub.sides.itemSources or {}) do
        for _, item in ipairs(transposer.items(sub.transposer, side) or {}) do
            if sameItem(item, required) and item.size > 0 then
                return side, item.slot, item.size
            end
        end
    end
    return nil, nil, 0
end



--- 投料泵：每拍最多推进一个小步骤；空队列零开销
function produceApp.pump()
    if not activeJob then
        if #machineQueue == 0 then
            scheduler.setEnabled("produce_feed", false)
            return
        end
        -- 每拍只启动一台；失败的任务已被标记为本周期放弃，绝不重排。
        local item = table.remove(machineQueue, 1)
        startJob(item.machine, item.seq)
    end
    if not activeJob then return end

    local job  = activeJob
    local item = job.items[job.index]
    if not item then
        finishJob(nil)
        return
    end

    local label = constants.levelLabel(job.level)
    local sub   = state.read.produce().subs[job.machine]
    if not sub or not sub.sides then
        finishJob("侧位/子系统已不可用")
        return
    end

    local moved, why = 0, nil

    if item.kind == "item" then
        if not sub.sides.itemTarget then
            logs.warn(string.format("%s 制作自动化：转运失败（机器 %s）", label, job.text))
            logs.debug(string.format("%s 制作自动化：转运失败明细——没有物品输出侧", label))
            failJob("没有物品输出侧", true)
            return
        end
        local sourceSide, slot, count = findItemSource(sub, item.item)
        if not sourceSide then
            logs.warn(string.format("%s 制作自动化：转运失败（机器 %s）", label, job.text))
            logs.debug(string.format("%s 制作自动化：转运失败明细——找不到%s的源槽",
                label, tostring(item.label or item.item.name)))
            failJob("找不到物品源槽", true)
            return
        end
        local want = math.min(item.remaining, count)
        local ok, movedOrWhy = transposer.transferItems(sub.transposer, sourceSide, sub.sides.itemTarget, want, slot)
        if not ok then
            logs.warn(string.format("%s 制作自动化：转运失败（机器 %s）", label, job.text))
            logs.debug(string.format("%s 制作自动化：转运失败明细——%s %d个：%s",
                label, tostring(item.label), want, tostring(movedOrWhy)))
            failJob("物品转运失败", true)
            return
        end
        moved = tonumber(movedOrWhy) or 0
    else
        local side, tank = findSource(sub, item.fluid)
        if not side then
            logs.warn(string.format("%s 制作自动化：转运失败（机器 %s）", label, job.text))
            logs.debug(string.format("%s 制作自动化：转运失败明细——找不到%s的源罐",
                label, tostring(item.label or item.fluid)))
            failJob("找不到源罐", true)
            return
        end
        local want = math.min(job.chunk, item.remaining)
        local ok, movedOrWhy = transposer.transfer(sub.transposer, side, sub.sides.target, want, tank)
        if not ok then
            logs.warn(string.format("%s 制作自动化：转运失败（机器 %s）", label, job.text))
            logs.debug(string.format("%s 制作自动化：转运失败明细——%s %dL：%s",
                label, tostring(item.label or item.fluid), want, tostring(movedOrWhy)))
            failJob("转运失败", true)
            return
        end
        moved = tonumber(movedOrWhy) or 0
    end

    if moved <= 0 then
        logs.warn(string.format("%s 制作自动化：转运失败（机器 %s）", label, job.text))
        logs.debug(string.format("%s 制作自动化：转运失败明细——%s：moved=0",
            label, tostring(item.label or item.fluid or item.item.name)))
        finishJob("转运失败")
        return
    end

    item.remaining = item.remaining - moved
    local name = tostring(item.label or item.fluid or (item.item and (item.item.label or item.item.name)) or "?")
    local key  = tostring(item.kind) .. ":" .. name
    local rec  = job.done[key]
    if not rec then
        rec = { label = name, unit = (item.kind == "item") and "个" or "L", amount = 0 }
        job.done[key] = rec
    end
    rec.amount = rec.amount + moved

    if item.remaining > 0 then
        return -- 下拍继续补这一笔的剩余
    end
    job.index = job.index + 1
    if job.index > #job.items then
        local parts = {}
        for _, done in pairs(job.done) do
            parts[#parts + 1] = string.format("%s %d%s", done.label, done.amount, done.unit)
        end
        table.sort(parts)
        finishJob(nil)
        logs.debug(string.format("%s 制作自动化：本周期投料完成（机器 %s）：%s",
            label, job.text, (#parts > 0) and table.concat(parts, "、") or "无成功笔数"))
    end
end


--- 周期边界检测（T3 的全局周期维护点调用；只做边沿判定 + 发事件）
-- @param progress number|nil 主机进度
-- @param maxProgress number|nil 主机最大进度
function produceApp.onCycleProgress(progress, maxProgress)
    if type(progress) ~= "number" then return end
    local cycle = state.read.produce().cycle
    local prev  = cycle.lastProgress
    state.write.produceSetCycle({ lastProgress = progress, progressMax = maxProgress })
    if prev == nil then return end

    -- 周期边界：进度回落（且已开工），或从 ≤1 升到 >1（覆盖开机后的第一个周期）
    local newCycle = (progress < prev and progress > 1) or (prev <= 1 and progress > 1)
    if not newCycle then return end

    local seq = (cycle.seq or 0) + 1
    state.write.produceSetCycle({ seq = seq })
    machineQueue = {} -- 旧周期的待投任务作废；activeJob 保留
    scheduler.emit("produce_cycle", { seq = seq })
end

--- 周期开始：一次性规划本周期任务；机器活跃状态复用同一次 T3 观测
-- @param payload table { seq = number }
function produceApp.onCycleStarted(payload)
    local seq = (payload and payload.seq) or state.read.produce().cycle.seq
    local ratio = cycleRatio()
    if ratio and ratio > (tonumber(CONFIG.PRODUCE.CYCLE_CUTOFF) or 0.9) then
        logs.debug(string.format("制作自动化：周期 #%s 已过 %d%%，本周期不规划任务",
            tostring(seq), math.floor(ratio * 100)))
        if not activeJob then scheduler.setEnabled("produce_feed", false) end
        return
    end

    local planned = 0
    for machine, sub in pairs(state.read.produce().subs) do
        local entry = state.read.produceLevel(sub.level)
        if entry.enabled == true and entry.valid == true
            and sub.forceOff ~= true
            and sub.sides ~= nil
            and (sub.cycleSeq or 0) ~= seq then
            -- 复用 T3 刚完成的那次观测：cycle 边沿本身就来自同一次采样，
            -- 不在周期边沿为每台机器额外发 component 请求。
            local fact = observedMachine(sub.level, machine)
            if fact and fact.switch == true and fact.active == true then
                machineQueue[#machineQueue + 1] = { machine = machine, seq = seq }
                planned = planned + 1
            end
        end
    end

    if planned > 0 then
        logs.debug(string.format("制作自动化：周期 #%s 规划投料任务 %d 台（每拍一笔）",
            tostring(seq), planned))
        scheduler.setEnabled("produce_feed", true)
    elseif not activeJob then
        scheduler.setEnabled("produce_feed", false)
    end
end

-- 对外：周期任务体（T8）
--------------------------------------------------------------------------------

--- 周期任务体：绑定中检测新转运器（只有"绑定中"才每秒枚举转运器）
-- 周期边界在 T3；在线 / 侧位 / 原料巡检在 T1；投料泵是独立的 0.05s 任务。
function produceApp.tick()
    local binding = state.read.produce().binding
    if binding then
        local list = device.scanTransposers()
        local news = {}
        for _, address in ipairs(list) do
            if not binding.snapshot[address] and not transposerBound(address) then
                news[#news + 1] = address
            end
        end
        if #news > 0 then
            local ok, err = commitBind(binding.level, binding.machine, news[1], string.format(
                "%s 制作自动化：已绑定 %s… → 机器 %s", constants.levelLabel(binding.level),
                utils.shortAddress(news[1]), machineTextOf(binding.level, binding.machine)))
            if ok then
                bindFailText = nil
            elseif tostring(err) ~= bindFailText then
                bindFailText = tostring(err)
                logs.warn(string.format("%s 制作自动化：绑定失败——%s（会继续重试）",
                    constants.levelLabel(binding.level), tostring(err)))
            end
            if #news > 1 then
                local unbound = 0
                for _, address in ipairs(list) do
                    if not transposerBound(address) then unbound = unbound + 1 end
                end
                logs.warn(string.format("%s 制作自动化：网络有 %d 个未绑定转运器",
                    constants.levelLabel(binding.level), unbound))
            end
        end
    end

end

return produceApp