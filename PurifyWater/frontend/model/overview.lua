--------------------------------------------------------------------------------
-- PurifyWater/frontend/model/overview.lua
--
-- 定位：总览页的 ViewModel 构造器。
-- 功能：同步生成状态、控制面板、等级行、周期进度、图表和日志视图。
-- 边界：只格式化读模型，不写业务状态，不做 GPU 绘制。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local util = require("shared.util")
local logs_model = require("frontend.model.logs")

local overview = {}

local function numberText(value)
    value = tonumber(value)
    if value == nil then return "-" end
    return util.formatShortNumber(value)
end

local function ageText(age)
    if age == nil then return "-" end
    return string.format("%.0fs", age)
end

local function hostText(switch)
    if switch == nil then return "读取失败", "danger" end
    if switch then return "已开启", "success" end
    return "已关闭", "danger"
end

--- 把只读快照转换为总览页 ViewModel。
function overview.build(read)
    local system = read.system or {}
    local hardware = read.hardware or {}
    local water = read.water or {}
    local host = read.host or {}
    local power = read.power or {}
    local sourceLevels = read.levels or {}
    local levels = {}
    local observedLevels = 0
    local machineTotal = 0
    for level = 1, constants.LEVEL_COUNT do
        local source = sourceLevels[level] or {}
        local value = tonumber(source.water)
        if value ~= nil then observedLevels = observedLevels + 1 end

        local rule = source.rule or {}
        local deployed = tonumber(source.deployed) or 0
        local active = tonumber(source.active)
        local base = tonumber(rule.effectiveThreshold) or 0

        local runText = deployed == 0 and "-" or ((active == nil) and "-" or (active .. "/" .. deployed))
        local switchText
        local switchRole
        if deployed == 0 then
            switchText, switchRole = "未部署", "danger"
        elseif source.switch == nil then
            switchText, switchRole = "读取失败", "danger"
        elseif source.switch then
            switchText, switchRole = "开 " .. runText, "success"
        else
            switchText, switchRole = "关 " .. runText, "warning"
        end

        local waterText = numberText(value)
        local thresholdText = numberText(rule.effectiveThreshold or 0)
        local sample = tonumber(source.sample)
        local learned = tonumber(source.learned)
        local suggest = tonumber(source.suggest)
        local sampleStale = (active or 0) == 0 and sample ~= nil
        local sampleRole = "text"
        if sampleStale then
            sampleRole = "disabled"
        elseif sample ~= nil and learned == sample then
            sampleRole = "accent"
        end
        local suggestRole = "text"
        if sample ~= nil and suggest ~= nil then
            suggestRole = suggest == sample and "accent" or "danger"
        end
        levels[level] = {
            level = level,
            label = constants.levelLabel(level),
            value = value,
            valueText = numberText(value),
            thresholdText = thresholdText,
            waterText = waterText,
            waterOfText = waterText .. "/" .. thresholdText,
            ratio = (value and base > 0) and math.min(1, value / base) or 0,
            role = value == nil and "disabled" or (value > 0 and "success" or "warning"),
            deployed = deployed,
            deployText = "×" .. tostring(deployed),
            active = active,
            running = deployed > 0 and (active or 0) > 0,
            runText = runText,
            switch = source.switch,
            switchText = switchText,
            switchRole = switchRole,
            sample = sample,
            sampleText = sample and numberText(sample) or "-",
            sampleRole = sampleRole,
            sampleStale = sampleStale,
            learned = learned,
            suggest = suggest,
            suggestText = suggest and numberText(suggest) or "-",
            suggestRole = suggestRole,
            machines = source.machines or {},
            successText = source.success and (tostring(source.success) .. "%") or "-",
            rateText = "成功率 " .. (source.success and (tostring(source.success) .. "%") or "-"),
            mark = rule.enabled and "[√]" or "[ ]",
            rule = rule,
        }
        machineTotal = machineTotal + deployed
    end

    local statusText = "等待采集"
    local statusRole = "disabled"
    if hardware.observed and water.observed then
        if system.awaiting then
            statusText, statusRole = "等待用户处理", "warning"
        else
            statusText = system.running and "自动调度中" or "停机待启动"
            statusRole = system.running and "success" or "disabled"
        end
    elseif hardware.observed or water.observed then
        statusText = "部分数据"
        statusRole = "warning"
    end

    local hostValue, hostRole = hostText(host.switch)
    local progress, progressMax = tonumber(host.progress), tonumber(host.progressMax)
    local cycleRatio = (progress and progressMax and progressMax > 0)
        and math.max(0, math.min(1, progress / progressMax)) or 0
    local cycleText = (progress and progressMax and progressMax > 0)
        and string.format("%d%%", math.floor(cycleRatio * 100 + 0.5)) or "未运行"

    local rateMode = system.mode == "rate"
    local controlRows = {
        { label = "系统状态：", value = statusText, role = statusRole },
        { label = "净水主机：", value = hostValue, role = hostRole },
        { label = "运行模式：", value = rateMode and "速率调度" or "阈值调度", role = "accent" },
        { label = "功率概况：", value = numberText(power.used or 0) .. " / " .. numberText(power.all or 0) .. " EU/t", role = "accent" },
        { label = "ME接口：", value = hardware.me and "已连接" or "未连接", role = hardware.me and "success" or "danger", optional = true },
        { label = "部署机器：", value = machineTotal .. " 台（T1–T8）", role = "accent" },
    }

    local net = read.net or {}
    return {
        revision = read.revision,
        title = "PurifyWater V2",
        version = constants.CODE_VERSION,
        status = { text = statusText, role = statusRole },
        summary = {
            hardwareText = hardware.observed
                and string.format("%d 个组件 · %s", hardware.count or 0, ageText(hardware.age))
                or "等待硬件",
            waterText = water.observed
                and string.format("%d/%d 级 · %s", observedLevels, constants.LEVEL_COUNT, ageText(water.age))
                or "等待水位",
            logText = string.format("%d 条", #(read.logs and read.logs.entries or {})),
        },
        control = {
            rows = controlRows,
            buttons = {
                system = {
                    label = system.running and "停机" or "启动系统",
                    action = "system_toggle",
                    role = system.running and "success" or "text",
                    active = system.running,
                },
                mode = {
                    label = rateMode and "切到阈值调度" or "切到速率调度",
                    action = "mode_toggle",
                    role = "accent",
                },
                subparam = {
                    label = rateMode
                        and (system.enforceThreshold and "阈值约束：开" or "阈值约束：关")
                        or (system.priority == "high" and "切到低级水优先" or "切到高级水优先"),
                    action = rateMode and "threshold_enforce_toggle" or "priority_toggle",
                    role = (not rateMode and system.priority == "high") and "danger" or "text",
                    background = (not rateMode and system.priority == "high") and "chipDanger" or nil,
                },
                refresh = { label = "刷新扫描", action = "refresh", role = "accent" },
                net = {
                    label = net.enabled and "无线广播：开" or "无线广播：关",
                    action = "net_toggle",
                    role = net.enabled and "accent" or "warning",
                    active = net.enabled,
                    disabled = net.available ~= true,
                },
                quit = { label = "退出程序", action = "quit", role = "danger" },
            },
        },
        cycle = { ratio = cycleRatio, text = cycleText },
        levels = levels,
        chart = {
            history = read.history or { times = {}, values = {} },
        },
        settings = {
            autostart = system.autostart == true,
            autostartStale = system.autostartStale == true,
            autostartPath = system.autostartPath,
        },
        logs = logs_model.build(read.logs),
    }
end

return overview
