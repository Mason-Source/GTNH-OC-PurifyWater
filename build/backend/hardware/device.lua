local component      = require("component")
local device         = {}
local ME_CANDIDATES  = { "fluid_interface", "me_interface" }
local NET_CANDIDATES = { "modem", "tunnel" }
local cache          = { me = false, net = false }
local sweepList      = {}
local machineAddrs   = {}
local function inCandidates(ctype, list)
    for _, candidate in ipairs(list) do
        if ctype == candidate then return true end
    end
    return false
end
function device.sweep()
    local out = {}
    for address, ctype in component.list() do
        out[#out + 1] = { address = address, ctype = ctype }
    end
    sweepList = out
end
function device.scanMe()
    for _, item in ipairs(sweepList) do
        if inCandidates(item.ctype, ME_CANDIDATES) then
            cache["me"] = { address = item.address, compType = item.ctype }
            return
        end
    end
    cache["me"] = false
end
function device.scanNet()
    for _, item in ipairs(sweepList) do
        if inCandidates(item.ctype, NET_CANDIDATES) then
            cache["net"] = { address = item.address, compType = item.ctype }
            return
        end
    end
    cache["net"] = false
end
function device.scanMachines()
    local out = {}
    for _, item in ipairs(sweepList) do
        if item.ctype == "gt_machine" then out[#out + 1] = item.address end
    end
    machineAddrs = out
    return out
end
function device.me()
    local hit = cache["me"]
    if hit then return hit.address, hit.compType end
    return nil, nil
end
function device.net()
    local hit = cache["net"]
    if hit then return hit.address, hit.compType end
    return nil, nil
end
function device.machines()
    return machineAddrs
end
function device.name(address)
    if not address then return nil end
    local name = device.invoke(address, "getName")
    if type(name) == "string" and name ~= "" then return name end
    return nil
end
function device.invoke(address, method, ...)
    if not address then return nil, "地址为空" end
    local ok, value, reason = pcall(component.invoke, address, method, ...)
    if not ok then return nil, tostring(value) end
    return value, nil, reason
end
return device
