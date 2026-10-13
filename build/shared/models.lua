local constants = require("shared.constants")
local models    = {}
function models.bool(value, default)
    if type(value) == "boolean" then return value end
    local s = tostring(value or ""):lower()
    if s == "" then return default ~= false end
    if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    return true
end
models.SNAP_VERSION = 11
local function clean(value)
    return (tostring(value == nil and "-" or value):gsub("[|\r\n]", "/"))
end
local function numOf(value)
    if value == nil then return "-" end
    return tostring(math.floor(tonumber(value) or 0))
end
local function flagOf(value)
    if value == nil then return "-" end
    return value and "1" or "0"
end
local function readFlag(s)
    if s == "1" then return true end
    if s == "0" then return false end
    return nil
end
local function split(line)
    local out = {}
    for token in tostring(line):gmatch("[^|]*") do out[#out + 1] = token end
    return out
end
function models.snapshot(payload)
    local lines       = {}
    local hw          = payload.hardware or {}
    local sy          = payload.system or {}
    local pw          = payload.power or {}
    local plan        = payload.plan or {}
    lines[#lines + 1] = table.concat({ "V", models.SNAP_VERSION }, "|")
    lines[#lines + 1] = table.concat({
        "S", flagOf(sy.running), flagOf(sy.awaiting), clean(sy.priority),
        flagOf((payload.host or {}).switch), clean(sy.mode), flagOf(sy.enforceThreshold),
        flagOf((sy.effectiveConfig or {}).enabled),
        numOf((payload.host or {}).progress), numOf((payload.host or {}).progressMax),
        flagOf((payload.net or {}).enabled)
    }, "|")
    lines[#lines + 1] = table.concat({
        "H", numOf(hw.host), numOf(hw.units), numOf(hw.energy),
        clean(table.concat(hw.missing or {}, ",")), flagOf(hw.me)
    }, "|")
    lines[#lines + 1] = table.concat({
        "P", numOf(pw.all), numOf(pw.used), clean(table.concat(plan.opened or {}, ","))
    }, "|")
    for _, row in ipairs(payload.levels or {}) do
        lines[#lines + 1] = table.concat({
            "L", numOf(row.level), numOf(row.deployed), flagOf(row.switch),
            numOf(row.active), numOf(row.water),
            numOf(row.rule and (row.rule.effectiveThreshold or row.rule.threshold)),
            flagOf(row.rule and row.rule.enabled),
            numOf(row.sample), numOf(row.suggest), numOf(row.success),
            numOf(row.parallel)
        }, "|")
        for _, machine in ipairs(row.machines or {}) do
            lines[#lines + 1] = table.concat({
                "M", numOf(row.level), flagOf(machine.active), numOf(machine.current),
                numOf(machine.confirmed), numOf(machine.success)
            }, "|")
        end
    end
    if payload.history then
        local times  = payload.history.times or {}
        local values = payload.history.values or {}
        for i = 1, #times do
            local nums = { "C", math.floor(times[i] or 0) }
            for level = 1, constants.LEVEL_COUNT do
                nums[#nums + 1] = math.floor((values[level] and values[level][i]) or 0)
            end
            lines[#lines + 1] = table.concat(nums, "|")
        end
    end
    for _, text in ipairs(payload.logs or {}) do
        lines[#lines + 1] = "G|" .. clean(text)
    end
    return table.concat(lines, "\n") .. "\n"
end
function models.parseSnapshot(text)
    local payload = {
        system = {},
        hardware = {},
        power = {},
        plan = { opened = {} },
        levels = {},
        logs = {}
    }
    local seen = false
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local f    = split(line)
        local mark = f[1]
        if mark == "V" then
            payload.version = tonumber(f[2]) or 0
            seen            = true
        elseif mark == "S" then
            payload.system = {
                running = readFlag(f[2]),
                awaiting = readFlag(f[3]),
                priority = f[4],
                mode = (f[6] and f[6] ~= "-") and f[6] or nil,
                enforceThreshold = readFlag(f[7]),
                effectiveConfig = { enabled = readFlag(f[8]) == true }
            }
            payload.host = {
                switch = readFlag(f[5] or "-"),
                progress = tonumber(f[9] or ""),
                progressMax = tonumber(f[10] or "")
            }
            payload.net = { enabled = readFlag(f[11]) == true, available = false }
        elseif mark == "H" then
            local missing = {}
            if f[5] and f[5] ~= "-" and f[5] ~= "" then
                for name in f[5]:gmatch("[^,]+") do missing[#missing + 1] = name end
            end
            payload.hardware = {
                host = tonumber(f[2]) or 0,
                units = tonumber(f[3]) or 0,
                energy = tonumber(f[4]) or 0,
                missing = missing,
                me = readFlag(f[6]) == true
            }
        elseif mark == "P" then
            payload.power = {
                all = tonumber(f[2]) or 0,
                used = tonumber(f[3]) or 0
            }
            local opened = {}
            if f[4] and f[4] ~= "-" and f[4] ~= "" then
                for value in f[4]:gmatch("[^,]+") do
                    local level = tonumber(value)
                    if level then opened[#opened + 1] = level end
                end
            end
            payload.plan = { opened = opened }
        elseif mark == "L" then
            local level = tonumber(f[2])
            if level then
                payload.levels[level] = {
                    level = level,
                    deployed = tonumber(f[3]) or 0,
                    switch = readFlag(f[4]),
                    active = tonumber(f[5]),
                    water = tonumber(f[6]),
                    rule = {
                        threshold          = tonumber(f[7]) or 0,
                        effectiveThreshold = tonumber(f[7]) or 0,
                        enabled            = readFlag(f[8]) == true
                    },
                    sample   = tonumber(f[9]),
                    suggest  = tonumber(f[10]),
                    success  = tonumber(f[11]),
                    parallel = tonumber(f[12])
                }
            end
        elseif mark == "M" then
            local level = tonumber(f[2])
            local row   = level and payload.levels[level]
            if row then
                row.machines = row.machines or {}
                row.machines[#row.machines + 1] = {
                    active    = readFlag(f[3]),
                    current   = tonumber(f[4]),
                    confirmed = tonumber(f[5]),
                    success   = tonumber(f[6])
                }
            end
        elseif mark == "C" then
            local t = tonumber(f[2])
            if t then
                local h = payload.history
                if not h then
                    h = { times = {}, values = {} }
                    for level = 1, constants.LEVEL_COUNT do h.values[level] = {} end
                    payload.history = h
                end
                h.times[#h.times + 1] = t
                for level = 1, constants.LEVEL_COUNT do
                    h.values[level][#h.values[level] + 1] = tonumber(f[2 + level]) or 0
                end
            end
        elseif mark == "G" then
            payload.logs[#payload.logs + 1] = tostring(f[2] or "")
        end
    end
    if not seen then return nil, "不是 v3 快照（缺少版本行）" end
    return payload
end
function models.chunk(message)
    local frame, index, total, part = tostring(message or ""):match("^v3|(%d+)|(%d+)|(%d+)|(.*)$")
    if not frame then return nil end
    return tonumber(frame), tonumber(index), tonumber(total), part
end
return models
