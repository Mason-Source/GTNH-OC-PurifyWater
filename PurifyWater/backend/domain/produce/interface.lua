--------------------------------------------------------------------------------
-- backend/domain/produce/interface.lua
--------------------------------------------------------------------------------
-- 【职责】统一读取制作方法可选接口，集中空实现判断
-- 【不做什么】不执行业务、不持有状态
--------------------------------------------------------------------------------

local interface = {}

local function call(method, name)
    local fn = method and method[name]
    if type(fn) ~= "function" then return nil end
    return fn()
end

function interface.requiredFluids(method) return call(method, "requiredFluids") end
function interface.requiredItems(method) return call(method, "requiredItems") end
function interface.stockRequirements(method) return call(method, "stockRequirements") end
function interface.patrolByNeed(method) return call(method, "patrolByNeed") == true end
function interface.minTransferRate(method) return call(method, "minTransferRate") end
function interface.operation(method) return method and method.operation or nil end
function interface.priority(method) return tonumber(method and method.priority) or nil end
function interface.recoversTargetItems(method)
    return method and method.recoversTargetItems == true
end

function interface.applicable(method)
    return interface.requiredFluids(method) ~= nil or interface.requiredItems(method) ~= nil
end

return interface
