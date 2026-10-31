-- 前端唯一读模型：只提供结构化状态，不包含文案、颜色或布局。
local constants = require("shared.constants")
local log = require("services.log")
local state = require("services.state")
local facts = require("services.facts")
local machines = require("hardware.machines")
local layout = require("business.produce.layout")
local util = require("shared.util")
local plan_model = require("business.plan")
local learning_service = require("services.learning_service")
local history_service = require("services.history_service")

local read_model = {}

local function factValue(slot)
    return slot and slot.value or nil
end

local function bindingFor(data, machine)
    for _, entry in ipairs(data.produce.bindings or {}) do
        if entry.machine == machine then return entry end
    end
    for _, entry in ipairs(data.produce.candidates or {}) do
        if entry.machine == machine then return entry end
    end
end

local function sideStateOf(entry)
    if not entry then return "未绑定" end
    if entry.miss then return string.format("转运器缺失 %d/%d", entry.miss, constants.PRODUCE_MISSING_SCANS or 3) end
    if entry.sideFail then return "失败·" .. tostring(entry.sideFail) end
    if entry.forceOff == true then return tostring(entry.forceReason or "原料不足") end
    if entry.sides and entry.slots and entry.slots.ready == true then return "配置就绪" end
    if entry.sides then return "槽位未就绪" end
    return "自动配置中"
end

local function machineView(data, address, name, present, x, y, z)
    local entry = bindingFor(data, address)
    local online
    if entry then online = data.produce.online[entry.transposer] end
    local sideState = sideStateOf(entry)
    local text
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then
        text = string.format("(%d,%d,%d)", x, y, z)
    else
        text = "无坐标(" .. util.shortAddress(address) .. ")"
    end
    return {
        address = address,
        name = name,
        x = x,
        y = y,
        z = z,
        text = text,
        bound = entry ~= nil,
        transposer = entry and entry.transposer or nil,
        transposerOnline = online,
        configured = entry and entry.sides ~= nil and entry.sideFail == nil
            and entry.slots ~= nil and entry.slots.ready == true or false,
        sideState = sideState,
        online = present == true,
    }
end

local function buildProduceLevels(data)
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        local stored = data.produce.levels[level] or {}
        local product = {}
        for key, value in pairs(stored) do product[key] = value end
        product.enabled = stored.enabled == true
        product.implemented = layout.implemented(level)

        local list, seen = {}, {}
        for _, machine in ipairs(machines.of(level)) do
            seen[machine.address] = true
            list[#list + 1] = machineView(data, machine.address, machine.name, machine.present, machine.x, machine.y, machine.z)
        end
        for _, entry in ipairs(data.produce.bindings or {}) do
            if entry.level == level and not seen[entry.machine] then
                seen[entry.machine] = true
                list[#list + 1] = machineView(data, entry.machine, entry.machine, false)
            end
        end
        for _, entry in ipairs(data.produce.candidates or {}) do
            if entry.level == level and not seen[entry.machine] then
                seen[entry.machine] = true
                list[#list + 1] = machineView(data, entry.machine, entry.machine, false)
            end
        end

        local bound, configured, online = 0, 0, 0
        for _, machine in ipairs(list) do
            if machine.bound then bound = bound + 1 end
            if machine.configured then configured = configured + 1 end
            if machine.transposerOnline == true then online = online + 1 end
        end

        local unbound = #list - bound
        local unavailable = bound - online
        local unconfigured = #list - configured
        local reason
        if #list == 0 then
            reason = "无机器"
        elseif unbound > 0 then
            reason = string.format("还有 %d 台未绑定", unbound)
        elseif unavailable > 0 then
            reason = string.format("有 %d 台转运器未就绪", unavailable)
        elseif unconfigured > 0 then
            reason = string.format("有 %d 台侧位未就绪", unconfigured)
        end

        product.machines = list
        product.count = #list
        product.bound = bound
        product.unbound = unbound
        product.configured = #list > 0 and configured == #list
        product.online = #list > 0 and online == #list
        product.ready = product.implemented and #list > 0
            and unbound == 0 and unavailable == 0 and unconfigured == 0
        product.reason = reason
        if not product.enabled then
            product.state = "未启用"
        elseif product.ready then
            product.state = "已就绪"
        else
            product.state = "未就绪"
        end
        out[level] = product
    end
    return out
end
function read_model.snapshot()
    local data = state.get()
    local hardware = factValue(data.facts.hardware)
    local water = factValue(data.facts.water)
    local produceLevels = buildProduceLevels(data)

    local levels = {}
    for level = 1, constants.LEVEL_COUNT do
        local machine = data.facts.levels[level] or {}
        local userThreshold = tonumber(data.settings.thresholds[level]) or 0
        local enabled = data.settings.enabledLevels[level]
        local lines = plan_model.lines(data, level)
        local learned = data.plan.learned[level]
        local machineFacts = {}
        for _, registered in ipairs(machines.of(level)) do
            local fact = data.facts.machines[registered.address] or {}
            machineFacts[#machineFacts + 1] = {
                address = registered.address,
                active = fact.active == true,
                current = fact.parallel,
                success = fact.success,
                confirmed = learning_service.confirmed(registered.address),
            }
        end
        levels[level] = {
            level = level,
            deployed = machine.deployed or 0,
            active = machine.active,
            water = water and water[level] or nil,
            switch = machine.switch,
            sample = machine.parallel,
            learned = learned and learned.parallel or nil,
            suggest = math.floor(tonumber(data.plan.suggest[level]) or 0),
            success = machine.success,
            machines = machineFacts,
            rule = {
                threshold = userThreshold,
                effectiveThreshold = lines.actual,
                userThreshold = lines.user,
                next = lines.next,
                overridden = lines.overridden,
                enabled = enabled ~= false,
            },
        }
    end

    local entries = log.entries()
    return {
        version = constants.CODE_VERSION,
        revision = tostring(state.revision()) .. ":" .. tostring(log.revision()),

        system = {
            running = data.control.session == "running",
            awaiting = data.control.awaiting == true,
            awaitingReason = data.control.awaitingReason,
            priority = data.settings.priority,
            mode = data.settings.mode,
            enforceThreshold = data.settings.enforceThreshold,
            theme = data.settings.theme,
            t7Boost = data.settings.t7Boost,
            reflux = data.settings.reflux,
            t6DualLithium = data.settings.t6DualLithium,
            energyFactor = data.settings.energyFactor,
            autostart = data.settings.autostart,
            autostartStale = data.settings.autostartStale,
            autostartPath = data.settings.autostartPath,
            effectiveConfig = {
                enabled = true,
                threshold = true,
                weight = true,
                boost = true,
            },
        },

        hardware = {
            observed = hardware ~= nil,
            count = (data.facts.hardware.summary and ((data.facts.hardware.summary.host or 0) + (data.facts.hardware.summary.unitTotal or 0))) or (hardware and #hardware or 0),
            age = facts.age(data.facts.hardware),
            me = data.facts.hardware.me == true,
            missing = data.facts.hardware.missing or {},
        },

        water = {
            observed = water ~= nil,
            levels = water,
            age = facts.age(data.facts.water),
        },

        host = {
            switch = data.facts.host.switch.value,
            active = data.facts.host.active.value,
            progress = data.facts.host.progress.value,
            progressMax = data.facts.host.progressMax.value,
            cycleSeq = data.facts.host.cycle.seq,
        },

        power = {
            all = data.power.available,
            max = data.power.max,
            used = data.power.used,
            budget = data.plan.budget,
        },

        levels = levels,

        settings = {
            weights = data.settings.weights,
            thresholds = data.settings.thresholds,
            enabledLevels = data.settings.enabledLevels,
            reflux = data.settings.reflux,
            t6DualLithium = data.settings.t6DualLithium,
            t7Boost = data.settings.t7Boost,
            energyFactor = data.settings.energyFactor,
            autostart = data.settings.autostart,
            autostartStale = data.settings.autostartStale,
            autostartPath = data.settings.autostartPath,
        },

        history = history_service.view(),

        net = {
            enabled = data.net.enabled == true,
            available = data.net.available == true,
            strength = data.net.strength or 0,
        },

        produce = {
            levels = produceLevels,
            binding = data.produce.binding,
            bindings = data.produce.bindings or {},
            candidates = data.produce.candidates or {},
            online = data.produce.online or {},
        },

        logs = {
            revision = log.revision(),
            entries = entries,
        },
    }
end

return read_model
