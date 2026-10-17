local t4 = {}
local ACID = "hydrochloricacid_gt5u" 
local ALKALINE = {
    name   = "gregtech:gt.metaitem.01",
    damage = 2685,
    label  = "氢氧化钠粉"
}
local PH_TARGET    = 7
local PH_TOLERANCE = 0.05
local PH_PER_DUST  = 0.01
local PH_PER_10_ACID = 0.01
function t4.requiredFluids() return { ACID } end
function t4.requiredItems() return { ALKALINE } end
function t4.usesItems() return true end
function t4.patrolByNeed() return true end
function t4.minTransferRate() return 50000 end
function t4.fluidUnit() return 10 end
local function phValue(lines)
    for _, raw in ipairs(lines or {}) do
        local text = tostring(raw):gsub("§.", "")
        local value = text:match("ph\\+([%d%.]+)%s*$")
        if value then return tonumber(value) end
    end
    return nil
end
function t4.need(lines)
    local ph = phValue(lines)
    if ph == nil then return nil, "读不到 pH", nil end
    if ph <= 0 then return nil, "pH 尚未初始化", ph end
    local errorValue = PH_TARGET - ph
    if math.abs(errorValue) <= PH_TOLERANCE then
        return {}, nil, ph
    end
    if errorValue > 0 then
        local count = math.floor(errorValue / PH_PER_DUST + 0.5)
        return { { item = ALKALINE, amount = count, label = "氢氧化钠粉" } }, nil, ph
    end
    local doses = math.floor((-errorValue) / PH_PER_10_ACID + 0.5)
    return { { fluid = ACID, amount = doses * 10, label = "氢氯酸" } }, nil, ph
end
return t4
