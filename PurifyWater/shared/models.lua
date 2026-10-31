-- 镜像快照编解码；纯函数，不使用 loadstring。
local constants = require("shared.constants")

local models = {}

models.SNAP_VERSION = 1
models.CHUNK_VERSION = "v2s"

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

local function readFlag(value)
    if value == "1" then return true end
    if value == "0" then return false end
    return nil
end

local function split(line)
    local out = {}
    for token in tostring(line):gmatch("[^|]*") do out[#out + 1] = token end
    return out
end

function models.encodeSnapshot(snapshot)
    snapshot = snapshot or {}
    local lines = {}
    local system = snapshot.system or {}
    local hardware = snapshot.hardware or {}
    local water = snapshot.water or {}
    local host = snapshot.host or {}
    local power = snapshot.power or {}
    local net = snapshot.net or {}
    local logs = snapshot.logs or {}

    lines[#lines + 1] = table.concat({ "V", models.SNAP_VERSION, clean(snapshot.version) }, "|")
    lines[#lines + 1] = "R|" .. clean(snapshot.revision)
    lines[#lines + 1] = table.concat({
        "S", flagOf(system.running), flagOf(system.awaiting), clean(system.priority),
        flagOf(host.switch), clean(system.mode), flagOf(system.enforceThreshold),
        numOf(host.progress), numOf(host.progressMax), flagOf(net.enabled),
    }, "|")
    lines[#lines + 1] = table.concat({
        "H", flagOf(hardware.observed), numOf(hardware.count), numOf(hardware.age),
        flagOf(hardware.me), clean(table.concat(hardware.missing or {}, ",")),
    }, "|")
    lines[#lines + 1] = table.concat({ "W", flagOf(water.observed), numOf(water.age) }, "|")
    lines[#lines + 1] = table.concat({
        "P", numOf(power.all), numOf(power.max), numOf(power.used), numOf(power.budget),
    }, "|")

    for level = 1, constants.LEVEL_COUNT do
        local row = (snapshot.levels or {})[level] or {}
        local rule = row.rule or {}
        lines[#lines + 1] = table.concat({
            "L", numOf(level), numOf(row.deployed), numOf(row.active), flagOf(row.switch),
            numOf(row.water), numOf(rule.effectiveThreshold), numOf(rule.userThreshold),
            numOf(rule.next), flagOf(rule.overridden), flagOf(rule.enabled),
            numOf(row.sample), numOf(row.learned), numOf(row.suggest), numOf(row.success),
        }, "|")
        for _, machine in ipairs(row.machines or {}) do
            lines[#lines + 1] = table.concat({
                "M", numOf(level), clean(machine.address), flagOf(machine.active),
                numOf(machine.current), numOf(machine.confirmed), numOf(machine.success),
            }, "|")
        end
    end

    local history = snapshot.history or {}
    lines[#lines + 1] = table.concat({
        "Y", numOf(history.interval), numOf(history.windowMinutes), numOf(history.count),
    }, "|")
    for slot = 1, tonumber(history.count) or 0 do
        local values = { "C", numOf(slot) }
        for level = 1, constants.LEVEL_COUNT do
            local series = (history.values or {})[level] or {}
            values[#values + 1] = numOf(series[slot])
        end
        lines[#lines + 1] = table.concat(values, "|")
    end

    lines[#lines + 1] = "GR|" .. numOf(logs.revision)
    for _, entry in ipairs(logs.entries or {}) do
        lines[#lines + 1] = table.concat({
            "G", numOf(entry.seq), numOf(entry.at), clean(entry.kind), clean(entry.text),
        }, "|")
    end

    return table.concat(lines, "\n")
end

function models.decodeSnapshot(text)
    local payload = {
        version = "-",
        revision = "?",
        system = {},
        hardware = {},
        water = {},
        host = {},
        power = {},
        net = { enabled = false, available = false },
        levels = {},
        history = { interval = 30, windowMinutes = 40, count = 0, values = {} },
        logs = { revision = 0, entries = {} },
    }
    for level = 1, constants.LEVEL_COUNT do payload.history.values[level] = {} end

    local seen = false
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local f = split(line)
        local mark = f[1]
        if mark == "V" then
            payload.snapVersion = tonumber(f[2])
            payload.version = f[3] or "-"
            seen = true
        elseif mark == "R" then
            payload.revision = f[2] or "?"
        elseif mark == "S" then
            payload.system = {
                running = readFlag(f[2]),
                awaiting = readFlag(f[3]),
                priority = f[4],
                mode = f[6],
                enforceThreshold = readFlag(f[7]),
            }
            payload.host = {
                switch = readFlag(f[5]),
                progress = tonumber(f[8]),
                progressMax = tonumber(f[9]),
            }
            payload.net.enabled = readFlag(f[10]) == true
        elseif mark == "H" then
            local missing = {}
            if f[6] and f[6] ~= "-" and f[6] ~= "" then
                for name in f[6]:gmatch("[^,]+") do missing[#missing + 1] = name end
            end
            payload.hardware = {
                observed = readFlag(f[2]) == true,
                count = tonumber(f[3]) or 0,
                age = tonumber(f[4]),
                me = readFlag(f[5]) == true,
                missing = missing,
            }
        elseif mark == "W" then
            payload.water = { observed = readFlag(f[2]) == true, age = tonumber(f[3]) }
        elseif mark == "P" then
            payload.power = {
                all = tonumber(f[2]) or 0,
                max = tonumber(f[3]) or 0,
                used = tonumber(f[4]) or 0,
                budget = tonumber(f[5]) or 0,
            }
        elseif mark == "L" then
            local level = tonumber(f[2])
            if level then
                payload.levels[level] = {
                    level = level,
                    deployed = tonumber(f[3]) or 0,
                    active = tonumber(f[4]),
                    switch = readFlag(f[5]),
                    water = tonumber(f[6]),
                    rule = {
                        effectiveThreshold = tonumber(f[7]),
                        userThreshold = tonumber(f[8]),
                        next = tonumber(f[9]),
                        overridden = readFlag(f[10]) == true,
                        enabled = readFlag(f[11]) == true,
                    },
                    sample = tonumber(f[12]),
                    learned = tonumber(f[13]),
                    suggest = tonumber(f[14]),
                    success = tonumber(f[15]),
                    machines = {},
                }
            end
        elseif mark == "M" then
            local level = tonumber(f[2])
            local row = level and payload.levels[level]
            if row then
                row.machines[#row.machines + 1] = {
                    address = f[3],
                    active = readFlag(f[4]),
                    current = tonumber(f[5]),
                    confirmed = tonumber(f[6]),
                    success = tonumber(f[7]),
                }
            end
        elseif mark == "Y" then
            payload.history.interval = tonumber(f[2]) or 30
            payload.history.windowMinutes = tonumber(f[3]) or 40
            payload.history.count = tonumber(f[4]) or 0
        elseif mark == "C" then
            for level = 1, constants.LEVEL_COUNT do
                local values = payload.history.values[level]
                values[#values + 1] = tonumber(f[2 + level]) or 0
            end
        elseif mark == "GR" then
            payload.logs.revision = tonumber(f[2]) or 0
        elseif mark == "G" then
            payload.logs.entries[#payload.logs.entries + 1] = {
                seq = tonumber(f[2]) or 0,
                at = tonumber(f[3]) or 0,
                kind = f[4] or "info",
                text = f[5] or "",
            }
        end
    end

    if not seen then return nil, "snapshot version line missing" end
    if payload.snapVersion ~= models.SNAP_VERSION then
        return nil, "snapshot version mismatch: " .. tostring(payload.snapVersion)
    end
    return payload
end

function models.chunk(frame, index, total, part)
    return table.concat({ models.CHUNK_VERSION, frame, index, total, part or "" }, "|")
end

function models.parseChunk(message)
    local frame, index, total, part = tostring(message or "")
        :match("^" .. models.CHUNK_VERSION .. "|(%d+)|(%d+)|(%d+)|(.*)$")
    if not frame then return nil end
    return tonumber(frame), tonumber(index), tonumber(total), part
end

return models