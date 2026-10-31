-- T0-8 设备注册表：已登记查存在性，未登记 gt_machine 补登记。
local constants = require("shared.constants")

local machines = {}

local byAddress = {}
local reg = { other = {} }
for level = 0, constants.LEVEL_COUNT do reg[level] = {} end
local energyItem = nil
local changed = false

local ENERGY_PATTERNS = {
    "hatch.energytunnel", "hatch.energywirelesstunnel",
    "hatch.energymulti", "hatch.energywirelessmulti",
    "wirelessenergyhatch",
}

local function isEnergy(name)
    name = tostring(name or "")
    for _, pattern in ipairs(ENERGY_PATTERNS) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end

local function wantsCoordinates(level)
    return type(level) == "number" and level >= 1 and level <= constants.LEVEL_COUNT
end

local function newEntry(level, address, name, x, y, z)
    if not wantsCoordinates(level) then x, y, z = nil, nil, nil end
    return {
        level = level,
        address = address,
        name = name,
        x = x,
        y = y,
        z = z,
        present = true,
        produce = {
            enabled = false,
            bound = false,
            transposer = nil,
            side = nil,
            slot = nil,
        },
    }
end

local function bucket(level)
    if level == "E" or level == "?" then return reg.other end
    local number = tonumber(level)
    if number and number >= 0 and number <= constants.LEVEL_COUNT then return reg[number] end
    return reg.other
end

local function removeFromBucket(entry)
    local list = bucket(entry.level)
    for index = #list, 1, -1 do
        if list[index] == entry then table.remove(list, index) end
    end
end

local function register(level, address, name, x, y, z)
    if byAddress[address] then return byAddress[address] end
    local entry = newEntry(level, address, name, x, y, z)
    byAddress[address] = entry
    table.insert(bucket(level), entry)
    if level == "E" and not energyItem then energyItem = entry end
    changed = true
    return entry
end

local function parseLine(line)
    local level, address, name, rest = tostring(line):match("^%s*(%S+)%s+(%S+)%s+(%S+)%s*(.-)%s*$")
    if not level or not address or not name then return nil end
    local x, y, z
    if rest and rest ~= "" then
        local px, py, pz = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
        x = px ~= "-" and tonumber(px) or nil
        y = py ~= "-" and tonumber(py) or nil
        z = pz ~= "-" and tonumber(pz) or nil
    end
    return level, address, name, x, y, z
end

function machines.load(lines)
    byAddress, reg, energyItem, changed = {}, { other = {} }, nil, false
    for level = 0, constants.LEVEL_COUNT do reg[level] = {} end

    for _, line in ipairs(lines or {}) do
        local level, address, name, x, y, z = parseLine(line)
        if address and name then
            if level ~= "E" and level ~= "?" then
                level = tonumber(level)
                if not level or level < 0 or level > constants.LEVEL_COUNT then level = "?" end
            end
            register(level, address, name, x, y, z)
        end
    end
    changed = false
end

function machines.needsCoordinates()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        for _, entry in ipairs(reg[level]) do
            if entry.x == nil or entry.y == nil or entry.z == nil then
                out[#out + 1] = entry.address
            end
        end
    end
    table.sort(out)
    return out
end

function machines.setCoordinates(address, x, y, z)
    local entry = byAddress[address]
    if not entry or not wantsCoordinates(entry.level) then return false end
    if entry.x ~= x or entry.y ~= y or entry.z ~= z then
        entry.x, entry.y, entry.z = x, y, z
        changed = true
        return true
    end
    return false
end

function machines.prepareScan(devices)
    local removed = {}
    for address, entry in pairs(byAddress) do
        if devices[address] ~= "gt_machine" then
            removed[#removed + 1] = entry
        else
            entry.present = true
        end
    end
    for _, entry in ipairs(removed) do
        byAddress[entry.address] = nil
        removeFromBucket(entry)
        if energyItem == entry then energyItem = nil end
        changed = true
    end

    local candidates = {}
    for address, kind in pairs(devices) do
        if kind == "gt_machine" and not byAddress[address] then
            candidates[#candidates + 1] = address
        end
    end
    table.sort(candidates)
    return candidates, removed
end

function machines.levelForName(name)
    local level = constants.MACHINE_NAMES[name]
    if level ~= nil then return level end
    if isEnergy(name) and not energyItem then return "E" end
    return "?"
end

function machines.update(address, name, x, y, z)
    local entry = byAddress[address]
    if not entry then return nil end

    local dirty = false
    if name and name ~= "" and name ~= entry.name then
        entry.name = name
        dirty = true
    end
    local level = entry.level
    if entry.name then
        if isEnergy(entry.name) and (entry.level == "E" or energyItem == entry) then
            level = "E"
        else
            level = machines.levelForName(entry.name)
        end
    end
    if level ~= entry.level then
        removeFromBucket(entry)
        entry.level = level
        local list = bucket(level)
        local found = false
        for _, existing in ipairs(list) do
            if existing == entry then found = true; break end
        end
        if not found then table.insert(list, entry) end
        if entry == energyItem and level ~= "E" then energyItem = nil end
        if level == "E" and energyItem == nil then energyItem = entry end
        dirty = true
    end

    if not wantsCoordinates(entry.level) then
        x, y, z = nil, nil, nil
    end
    if x ~= nil and y ~= nil and z ~= nil
        and (entry.x ~= x or entry.y ~= y or entry.z ~= z) then
        entry.x, entry.y, entry.z = x, y, z
        dirty = true
    end
    entry.present = true
    if dirty then changed = true end
    return entry
end

function machines.add(address, name, x, y, z)
    if byAddress[address] then return byAddress[address] end
    local level = machines.levelForName(name)
    return register(level, address, name, x, y, z)
end

function machines.isRegistered(address)
    return byAddress[address] ~= nil
end

function machines.of(level)
    return reg[level] or {}
end

function machines.energy()
    return energyItem
end

function machines.all()
    return byAddress
end

function machines.summary()
    local units, total = {}, 0
    for level = 1, constants.LEVEL_COUNT do
        local count = 0
        for _, entry in ipairs(reg[level]) do
            if entry.present then count = count + 1 end
        end
        units[level] = count
        total = total + count
    end
    local host = 0
    for _, entry in ipairs(reg[0]) do if entry.present then host = host + 1 end end
    return {
        host = host,
        unitTotal = total,
        units = units,
        energy = energyItem ~= nil,
        other = #reg.other,
    }
end

local function coordinatesText(entry)
    local x = entry.x ~= nil and tostring(entry.x) or "-"
    local y = entry.y ~= nil and tostring(entry.y) or "-"
    local z = entry.z ~= nil and tostring(entry.z) or "-"
    return x, y, z
end

function machines.topologyLines()
    local lines = {}
    for level = 0, constants.LEVEL_COUNT do
        for _, entry in ipairs(reg[level]) do
            local x, y, z = coordinatesText(entry)
            if not wantsCoordinates(level) then x, y, z = "-", "-", "-" end
            lines[#lines + 1] = string.format("%d %s %s %s %s %s",
                level, entry.address, entry.name, x, y, z)
        end
    end
    for _, entry in ipairs(reg.other) do
        lines[#lines + 1] = string.format("%s %s %s - - -",
            entry.level, entry.address, entry.name)
    end
    table.sort(lines)
    return lines
end

function machines.consumeChanged()
    local value = changed
    changed = false
    return value
end

function machines.markChanged()
    changed = true
end

return machines
