local t3 = {}
local FLUID  = "polyaluminiumchloride"
local AMOUNT = 900000
local ENTRY = { fluid = FLUID, amount = AMOUNT, label = "聚氯化铝" }
function t3.requiredFluids() return { FLUID } end
function t3.stockRequirements() return { ENTRY } end
function t3.minTransferRate() return 2621440 end
function t3.need(lines) return { ENTRY } end
return t3
