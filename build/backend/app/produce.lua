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
local bindFailText   = nil
local function bindLess(a, b)
    if a.level ~= b.level then return a.level < b.level end
    return tostring(a.machine) < tostring(b.machine)
end
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
local function bindOf(machine)
    for _, b in ipairs(state.read.produce().binds) do
        if b.machine == machine then return b end
    end
    return nil
end
local function transposerBound(address)
    for _, b in ipairs(state.read.produce().binds) do
        if b.transposer == address then return true end
    end
    return false
end
local function onlineSet()
    return state.read.produce().online
end
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
local function machineSetOf(level)
    local out = {}
    for _, m in ipairs(machines.of(level)) do out[m.address] = true end
    return out
end
local function observedMachine(level, machine)
    for _, fact in ipairs(state.read.plant(level).machines or {}) do
        if fact.address == machine then return fact end
    end
    return nil
end
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
local function blockedReasonOf(level)
    for _, sub in pairs(state.read.produce().subs) do
        if sub.level == level and sub.forceOff == true then
            return sub.forceReason or "原料不足"
        end
    end
    return nil
end
local function stateOf(level)
    local entry = state.read.produceLevel(level)
    if entry.valid ~= true then return "invalid", entry.validReason or "未就绪" end
    if entry.enabled ~= true then return "off", nil end
    local blocked = blockedReasonOf(level)
    if blocked then return "blocked", blocked end
    return "ok", nil
end
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
local function applyBinds()
    local old  = state.read.produce().subs
    local subs = {}
    for _, b in ipairs(state.read.produce().binds) do
        local keep = old[b.machine] or {}
        local same = (keep.transposer == b.transposer)
        local sides, layout
        if keep.transposer == nil then
            sides, layout = b.sides, b.layout
        elseif same then
            sides  = keep.sides or b.sides
            layout = keep.layout or b.layout
        end
        subs[b.machine] = {
            level       = b.level,
            transposer  = b.transposer,
            rate        = same and keep.rate or nil,
            cycleSeq    = keep.cycleSeq or 0,
            sides       = sides,
            sideTarget  = sides and sides.target or nil,
            itemTarget  = sides and sides.itemTarget or nil,
            sideFail    = same and keep.sideFail or nil,
            layout      = layout,
            forceOff    = same and keep.forceOff or nil,
            forceReason = same and keep.forceReason or nil
        }
    end
    state.write.produceSetSubs(subs)
end
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
local function sameItem(a, b)
    return a ~= nil and b ~= nil
        and a.name == b.name
        and (tonumber(a.damage) or 0) == (tonumber(b.damage) or 0)
end
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
local function scanSides(address, needItems)
    local out = {}
    for side = 0, 5 do
        local fluids   = transposer.containers(address, side)
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
    saveSideConfig(machine, sides, layout)
    return true, nil, detail, sides
end
local function layoutSignature(sub, needItems)
    local info = scanSides(sub.transposer, needItems)
    local parts = {}
    for side, entry in pairs(info) do
        parts[#parts + 1] = signatureOf(side, entry)
    end
    table.sort(parts)
    return table.concat(parts, "|")
end
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
                        stock = nil
                    else
                        stock = demand
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
local function notify(reason)
    scheduler.emit("produce_changed", { reason = reason })
end
local function commitBind(level, machine, transposerAddress, message)
    local binds = {}
    for _, b in ipairs(state.read.produce().binds) do
        if b.machine ~= machine then binds[#binds + 1] = b end
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
function produceApp.refresh()
    refreshOnline()
    return refreshAll()
end
function produceApp.beginBind(level, machine)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if type(machine) ~= "string" or machine == "" then return false, "机器无效" end
    if state.read.produce().binding then return false, "已有正在进行的绑定，请先取消" end
    refreshOnline()
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
function produceApp.cancelBind()
    local binding = state.read.produce().binding
    if not binding then return false, "当前没有正在进行的绑定" end
    state.write.produceSetBinding(nil)
    logs.system(string.format("%s 制作自动化：已取消绑定", constants.levelLabel(binding.level)))
    notify("取消绑定")
    return true, ""
end
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
            configured = configured,
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
local machineQueue = {}
local activeJob    = nil
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
local function cycleRatio()
    local cycle = state.read.produce().cycle
    local progress, max = cycle.lastProgress, cycle.progressMax
    if type(progress) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
    return progress / max
end
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
local function failJob(reason, reconfig)
    local job = activeJob
    if not job then return end
    if reconfig then produceApp.reconfigure(job.machine, reason) end
    finishJob(reason)
end
local function startJob(machine, seq)
    local sub = state.read.produce().subs[machine]
    if not sub or (sub.cycleSeq or 0) == seq then return false end
    local label  = constants.levelLabel(sub.level)
    local text   = machineTextOf(sub.level, machine)
    local method = produce.method(sub.level)
    if not sub.sides then
        logs.debug(string.format("%s 制作自动化：侧位未配置，本周期放弃（机器 %s）", label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end
    local fact = observedMachine(sub.level, machine)
    if not fact or fact.switch ~= true or fact.active ~= true then
        logs.debug(string.format("%s 制作自动化：观测到的机器未开启/未运行，本周期放弃本次任务（机器 %s）",
            label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end
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
    if sub.forceOff == true then
        logs.debug(string.format("%s 制作自动化：原料不足，本周期放弃（机器 %s）", label, text))
        state.write.produceSetSub(machine, { cycleSeq = seq })
        return false
    end
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
function produceApp.pump()
    if not activeJob then
        if #machineQueue == 0 then
            scheduler.setEnabled("produce_feed", false)
            return
        end
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
        return
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
function produceApp.onCycleProgress(progress, maxProgress)
    if type(progress) ~= "number" then return end
    local cycle = state.read.produce().cycle
    local prev  = cycle.lastProgress
    state.write.produceSetCycle({ lastProgress = progress, progressMax = maxProgress })
    if prev == nil then return end
    local newCycle = (progress < prev and progress > 1) or (prev <= 1 and progress > 1)
    if not newCycle then return end
    local seq = (cycle.seq or 0) + 1
    state.write.produceSetCycle({ seq = seq })
    machineQueue = {}
    scheduler.emit("produce_cycle", { seq = seq })
end
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
