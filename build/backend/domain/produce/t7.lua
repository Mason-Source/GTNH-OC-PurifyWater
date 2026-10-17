local t7 = {}
local SUPERCONDUCTORS = {
    "molten.longasssuperconductornameforuvwire",
    "molten.longasssuperconductornameforuhvwire",
    "molten.superconductoruevbase",
    "molten.superconductoruivbase",
    "molten.superconductorumvbase"
}
local SUPERCOOLANT   = { fluid = "supercoolant", amount = 10000, label = "超级冷却液" }
local GAS_HE         = { fluid = "helium",  amount = 10000, label = "氦" }
local GAS_NE         = { fluid = "neon",    amount = 7500,  label = "氖" }
local GAS_KR         = { fluid = "krypton", amount = 5000,  label = "氪" }
local GAS_XE         = { fluid = "xenon",   amount = 2500,  label = "氙" }
local SUPERCONDUCTOR = { any = SUPERCONDUCTORS, amount = 1440, label = "熔融超导粗胚" }
local NEUTRONIUM     = { fluid = "molten.neutronium", amount = 4608, label = "熔融中子" }
local STOCK = { SUPERCOOLANT, GAS_HE, SUPERCONDUCTOR, GAS_NE, NEUTRONIUM, GAS_KR, GAS_XE }
local FLUIDS = {
    SUPERCOOLANT.fluid,
    GAS_HE.fluid,
    { label = "熔融超导粗胚（UV-UMV 任意）", any = SUPERCONDUCTORS },
    GAS_NE.fluid,
    NEUTRONIUM.fluid,
    GAS_KR.fluid,
    GAS_XE.fluid
}
function t7.stockRequirements() return STOCK end
function t7.minTransferRate() return 200000 end
function t7.requiredFluids() return FLUIDS end
local function controlValue(lines)
    for _, raw in ipairs(lines or {}) do
        local text = tostring(raw):gsub("§.", "")
        local tail = text:match("control_signal\\+(%d+)%s*$")
        if tail then return tonumber(tail, 2) end
    end
    return nil
end
function t7.need(lines)
    local n = controlValue(lines)
    if n == nil then return nil, "读不到控制信号", nil end
    if n >= 8 then return {}, nil, n end
    if n == 0 then
        return { SUPERCOOLANT }, nil, n
    end
    local out = {}
    if n % 2 == 1 then
        local gas = math.floor(n / 2) % 4
        if gas == 0 then out[#out + 1] = GAS_HE
        elseif gas == 1 then out[#out + 1] = GAS_NE
        elseif gas == 2 then out[#out + 1] = GAS_KR
        else out[#out + 1] = GAS_XE end
    end
    if math.floor(n / 2) % 2 == 1 then
        out[#out + 1] = SUPERCONDUCTOR
    end
    if math.floor(n / 4) % 2 == 1 then
        out[#out + 1] = NEUTRONIUM
    end
    return out, nil, n
end
return t7
