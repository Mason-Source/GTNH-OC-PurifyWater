local constants       = require("shared.constants")
local device          = require("backend.hardware.device")
local machines        = {}
local reg             = {}
local energyItem      = nil
local otherReg        = {}
local ENERGY_PATTERNS = {
    "hatch.energytunnel", "hatch.energywirelesstunnel",
    "hatch.energymulti", "hatch.energywirelessmulti"
}
local function isEnergy(name)
    for _, pattern in ipairs(ENERGY_PATTERNS) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end
for level = 0, constants.LEVEL_COUNT do reg[level] = {} end
function machines.scan()
    for level = 0, constants.LEVEL_COUNT do reg[level] = {} end
    energyItem, otherReg = nil, {}
    for _, address in ipairs(device.machines()) do
        local name = device.name(address)
        if name then
            local level = constants.MACHINE_NAMES[name]
            if level then
                reg[level][#reg[level] + 1] = { address = address, name = name }
            elseif isEnergy(name) then
                if energyItem then
                    otherReg[#otherReg + 1] = { address = address, name = name }
                else
                    energyItem = { address = address, name = name }
                end
            else
                otherReg[#otherReg + 1] = { address = address, name = name }
            end
        end
    end
    return machines.summary()
end
function machines.summary()
    local units, unitTotal = {}, 0
    for level = 1, constants.LEVEL_COUNT do
        units[level] = #reg[level]
        unitTotal = unitTotal + units[level]
    end
    return {
        host = #reg[0],
        unitTotal = unitTotal,
        units = units,
        energy = energyItem ~= nil,
        other = #otherReg
    }
end
function machines.of(level)
    return reg[level] or {}
end
function machines.energy()
    return energyItem
end
function machines.topology()
    local out = {}
    for level = 0, constants.LEVEL_COUNT do
        for _, m in ipairs(reg[level]) do
            out[#out + 1] = { level = level, address = m.address, name = m.name }
        end
    end
    if energyItem then
        out[#out + 1] = { level = "E", address = energyItem.address, name = energyItem.name }
    end
    for _, m in ipairs(otherReg) do
        out[#out + 1] = { level = "?", address = m.address, name = m.name }
    end
    return out
end
return machines
