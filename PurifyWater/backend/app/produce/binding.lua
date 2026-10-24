--------------------------------------------------------------------------------
-- backend/app/produce/binding.lua
--------------------------------------------------------------------------------
-- 【职责】机器↔转运器绑定、在线状态、机器快照查询、绑定表持久化
-- 【不做什么】不判等级就绪、不扫侧位、不做库存巡检
--------------------------------------------------------------------------------

local constants     = require("shared.constants")
local logs          = require("shared.logs")
local state         = require("shared.state")
local utils         = require("shared.utils")

local device        = require("backend.hardware.device")
local machines      = require("backend.hardware.machines")
local transposer    = require("backend.hardware.transposer")
local produce_table = require("backend.store.produce")
local reconcile     = require("backend.domain.produce.reconcile")

local binding = {}

local byMachine, byTransposer = {}, {}

--- 重建绑定索引（machine/transposer -> bind）
local function rebuildIndex()
    byMachine, byTransposer = {}, {}
    for _, b in ipairs(state.read.produce().binds) do
        byMachine[b.machine] = b
        byTransposer[b.transposer] = b
    end
end
binding.rebuildIndex = rebuildIndex

--- 绑定排序（先级后机器）
local function bindLess(a, b)
    if a.level ~= b.level then return a.level < b.level end
    return tostring(a.machine) < tostring(b.machine)
end

--- 机器显示文本：优先坐标，坐标不可用退回短地址
function binding.machineTextOf(level, address)
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

--- 从绑定表找某台机器
function binding.bindOf(machine)
    if #state.read.produce().binds > 0 and next(byMachine) == nil then rebuildIndex() end
    return byMachine[machine]
end

--- 某转运器是否已绑给活跃机器，或被删除候选保留
-- 候选机器重新出现前，其转运器不能被别的机器抢走。
function binding.transposerBound(address)
    if #state.read.produce().binds > 0 and next(byTransposer) == nil then rebuildIndex() end
    if byTransposer[address] ~= nil then return true end
    for _, candidate in ipairs(state.read.produce().candidates or {}) do
        if candidate.transposer == address then return true end
    end
    return false
end

--- 删除候选池（只读）
function binding.candidates() return state.read.produce().candidates or {} end

--- 已绑定转运器在线表
function binding.onlineSet() return state.read.produce().online end

--- 检查已绑定转运器在线并缓存速率
function binding.refreshOnline(forceRate)
    local map = {}
    local old = state.read.produce().online
    for _, b in ipairs(state.read.produce().binds) do
        local now = device.isTransposerOnline(b.transposer)
        local sub = state.read.produce().subs[b.machine]
        local rate = sub and sub.rate or nil
        if now and (forceRate == true or old[b.transposer] == nil
            or old[b.transposer] == false or type(rate) ~= "number") then
            rate = transposer.rate(b.transposer)
        end
        state.write.produceSetSub(b.machine, { rate = now and rate or nil })
        local was = old[b.transposer]
        if was ~= nil and was ~= now then
            if now then
                logs.system(string.format("%s 制作自动化：转运器 %s… 已恢复在线",
                    constants.levelLabel(b.level), utils.shortAddress(b.transposer)))
            else
                logs.warn(string.format("%s 制作自动化：转运器 %s… 掉线（机器 %s）",
                    constants.levelLabel(b.level), utils.shortAddress(b.transposer),
                    binding.machineTextOf(b.level, b.machine)))
            end
        end
        map[b.transposer] = now
    end
    state.write.produceSetOnlineAll(map)
end

--- 某级注册表机器地址集合
function binding.machineSet(level)
    local out = {}
    for _, m in ipairs(machines.of(level)) do out[m.address] = true end
    return out
end

--- 全等级注册表
local function registryMap()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do out[level] = binding.machineSet(level) end
    return out
end

--- T3 最近一次观测到的单台机器事实
function binding.observedMachine(level, machine)
    for _, fact in ipairs(state.read.plant(level).machines or {}) do
        if fact.address == machine then return fact end
    end
    return nil
end

--- 组装 produce.check() 所需的本级机器数组
function binding.units(level)
    local online = binding.onlineSet()
    local out, seen = {}, {}
    for _, m in ipairs(machines.of(level)) do
        seen[m.address] = true
        local b = binding.bindOf(m.address)
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
            local sub = state.read.produce().subs[b.machine]
            out[#out + 1] = {
                machine    = b.machine,
                transposer = b.transposer,
                online     = online[b.transposer] or nil,
                rate       = (online[b.transposer] and sub) and sub.rate or nil
            }
        end
    end
    return out
end

--- 按绑定表重建运行时子系统，同机器同转运器保留状态
function binding.rebuildSubs()
    local old  = state.read.produce().subs
    local subs = {}
    for _, b in ipairs(state.read.produce().binds) do
        local keep = old[b.machine]
        local same = keep and keep.transposer == b.transposer
        local sub  = same and keep or { transposer = b.transposer, cycleSeq = 0 }
        local sides, layout
        if not keep then
            sides, layout = b.sides, b.layout
        elseif same then
            sides  = keep.sides or b.sides
            layout = keep.layout or b.layout
        end
        sub.level       = b.level
        sub.sides       = sides
        sub.layout      = layout
        subs[b.machine] = sub
    end
    state.write.produceSetSubs(subs)
    rebuildIndex()
end

--- 更新一台机器的侧位并落盘
function binding.updateSide(machine, sides, layout)
    local b = binding.bindOf(machine)
    if not b then return false, "该机器未绑定" end
    local oldSides, oldLayout = b.sides, b.layout
    b.sides, b.layout = sides, layout
    local ok, err = produce_table.save(state.read.produce().binds, state.read.produce().candidates)
    if not ok then
        b.sides, b.layout = oldSides, oldLayout
        return false, tostring(err)
    end
    return true, nil
end

--- 提交一条绑定（新增或替换旧转运器）
function binding.commit(level, machine, transposerAddress)
    local binds = state.read.produce().binds
    local old
    for _, b in ipairs(binds) do
        if b.machine == machine then
            old = { level = b.level, transposer = b.transposer, sides = b.sides, layout = b.layout }
            b.level, b.transposer, b.sides, b.layout = level, transposerAddress, nil, nil
            break
        end
    end
    local added
    if not old then
        added = { level = level, machine = machine, transposer = transposerAddress }
        binds[#binds + 1] = added
    end
    table.sort(binds, bindLess)

    local ok, err = produce_table.save(binds, state.read.produce().candidates)
    if not ok then
        if old then
            for _, b in ipairs(binds) do
                if b.machine == machine then
                    b.level, b.transposer, b.sides, b.layout =
                        old.level, old.transposer, old.sides, old.layout
                    break
                end
            end
        elseif added then
            for i, b in ipairs(binds) do
                if b == added then table.remove(binds, i); break end
            end
        end
        return false, "写绑定表失败（data/produce.txt）：" .. tostring(err)
    end

    local currentBinding = state.read.produce().binding
    if currentBinding and currentBinding.machine == machine then
        state.write.produceSetBinding(nil)
    end
    binding.rebuildSubs()
    binding.refreshOnline()
    return true, nil
end

--- 解绑一台机器
function binding.remove(machine)
    local binds = state.read.produce().binds
    local index, removed
    for i, b in ipairs(binds) do
        if b.machine == machine then index, removed = i, b; break end
    end
    if not index then return false, nil, "该机器未绑定" end

    table.remove(binds, index)
    local ok, err = produce_table.save(binds, state.read.produce().candidates)
    if not ok then
        table.insert(binds, index, removed)
        return false, nil, "写绑定表失败（data/produce.txt）：" .. tostring(err)
    end
    local currentBinding = state.read.produce().binding
    if currentBinding and currentBinding.machine == machine then
        state.write.produceSetBinding(nil)
    end
    binding.rebuildSubs()
    binding.refreshOnline()
    return true, removed, nil
end

--- T1 扫描后对账：活跃绑定 -> 删除候选 -> 恢复 / 到期删除
-- 纯判定在 domain/produce/reconcile；本函数只负责原子写盘和应用内存状态。
-- @param scanTrusted boolean 本轮扫描是否可信；不可信时不推进 miss 计数
-- @return table|nil 对账结果
-- @return string|nil 写盘错误
function binding.reconcileScan(scanTrusted)
    local current = state.read.produce()
    local result = reconcile.run(
        current.binds, current.candidates or {}, registryMap(), scanTrusted == true)
    if result.scanSkipped or not result.dirty then return result, nil end

    local ok, err = produce_table.save(result.active, result.candidates)
    if not ok then
        return nil, "写绑定表失败（data/produce.txt）：" .. tostring(err)
    end

    state.write.produceSetBinds(result.active)
    state.write.produceSetCandidates(result.candidates)

    local currentBinding = state.read.produce().binding
    if currentBinding then
        for _, action in ipairs(result.quarantined) do
            if action.entry.machine == currentBinding.machine then
                state.write.produceSetBinding(nil)
                break
            end
        end
    end

    binding.rebuildSubs()
    return result, nil
end

--- 整表替换（启动读盘）
function binding.replaceAll(entries, candidates)
    state.write.produceSetBinds(entries or {})
    state.write.produceSetCandidates(candidates or {})
    binding.rebuildSubs()
    binding.refreshOnline()
end

return binding
