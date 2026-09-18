local constants = require("shared.constants")
local utils     = require("shared.utils")
local models    = {}
function models.levelRule(line)
    local s = tostring(line or ""):gsub("^%s+", "")
    if s == "" or s:sub(1, 1) == "#" then return nil end
    local lv, threshold, enabled = s:match("^(%d+)%s+([%d%.eE%+%-]+)%s*(%S*)")
    lv = tonumber(lv)
    if not lv or lv < 1 or lv > constants.LEVEL_COUNT then return nil end
    local on = true
    local e = tostring(enabled or ""):lower()
    if e == "false" or e == "0" or e == "no" or e == "off" then on = false end
    return lv, tonumber(threshold), on
end
function models.levelRuleLine(level, threshold, enabled)
    return string.format("%d %d %s", level, math.floor(tonumber(threshold) or 0),
        enabled and "true" or "false")
end
function models.record(line)
    local s = tostring(line or ""):gsub("^%s+", "")
    if s == "" or s:sub(1, 1) == "#" then return nil end
    local lv, parallel, success, stamp = s:match("^(%d+)%s+(%d+)%s*(%S*)%s*(%S*)")
    lv = tonumber(lv)
    if not lv or lv < 1 or lv > constants.LEVEL_COUNT then return nil end
    return {
        level    = lv,
        parallel = tonumber(parallel),
        success  = tonumber(success),
        stamp    = tonumber(stamp)
    }
end
function models.recordLine(level, parallel, success, stamp)
    return string.format("%d %d %s %s", math.floor(tonumber(level) or 0),
        math.floor(tonumber(parallel) or 0), tostring(success or "-"),
        string.format("%.1f", tonumber(stamp) or 0))
end
function models.powerSnapshot(line)
    local s = tostring(line or "")
    if s:sub(1, 1) ~= "#" then return nil end
    return utils.firstNumber(s)
end
models.SNAP_VERSION = 6
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
        "S", flagOf(sy.running), flagOf(sy.locked), clean(sy.priority),
        flagOf((payload.host or {}).switch)
    }, "|")
    lines[#lines + 1] = table.concat({
        "H", numOf(hw.host), numOf(hw.units), numOf(hw.energy),
        clean(table.concat(hw.missing or {}, ","))
    }, "|")
    lines[#lines + 1] = table.concat({
        "P", numOf(pw.all), numOf(pw.used), clean(table.concat(plan.opened or {}, ","))
    }, "|")
    for _, row in ipairs(payload.levels or {}) do
        lines[#lines + 1] = table.concat({
            "L", numOf(row.level), numOf(row.deployed), flagOf(row.switch),
            numOf(row.active), numOf(row.water), numOf(row.rule and row.rule.threshold),
            flagOf(row.openable), flagOf(row.forced), clean(row.reason)
        }, "|")
    end
    return table.concat(lines, "\n") .. "\n"
end
function models.parseSnapshot(text)
    local payload = {
        system = {},
        hardware = {},
        power = {},
        plan = { opened = {} },
        levels = {}
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
                locked = readFlag(f[3]),
                priority = f[4]
            }
            payload.host = { switch = readFlag(f[5] or "-") }
        elseif mark == "H" then
            local missing = {}
            if f[5] and f[5] ~= "-" and f[5] ~= "" then
                for name in f[5]:gmatch("[^,]+") do missing[#missing + 1] = name end
            end
            payload.hardware = {
                host = tonumber(f[2]) or 0,
                units = tonumber(f[3]) or 0,
                energy = tonumber(f[4]) or 0,
                missing = missing
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
                    rule = { threshold = tonumber(f[7]) or 0 },
                    openable = readFlag(f[8]),
                    forced = readFlag(f[9]),
                    reason = f[10]
                }
            end
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
