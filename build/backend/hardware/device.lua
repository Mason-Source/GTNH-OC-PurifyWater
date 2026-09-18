local component      = require("component")
local device         = {}
local ME_CANDIDATES  = { "fluid_interface", "me_dual_interface", "me_interface" }
local NET_CANDIDATES = { "modem", "tunnel" }
local cache          = {}
local function find(kind, candidates)
    local hit = cache[kind]
    if hit == false then return nil, nil end
    if hit and hit.address then return hit.address, hit.compType end
    for _, compType in ipairs(candidates) do
        local address = component.list(compType)()
        if address then
            cache[kind] = { address = address, compType = compType }
            return address, compType
        end
    end
    cache[kind] = false
    return nil, nil
end
function device.me() return find("me", ME_CANDIDATES) end
function device.net() return find("net", NET_CANDIDATES) end
function device.invalidate()
    cache = {}
end
function device.machines()
    local out = {}
    for address in component.list("gt_machine") do
        out[#out + 1] = address
    end
    return out
end
function device.name(address)
    if not address then return nil end
    local name = device.invoke(address, "getName")
    if type(name) == "string" and name ~= "" then return name end
    return nil
end
function device.invoke(address, method, ...)
    if not address then return nil, "地址为空" end
    local ok, value = pcall(component.invoke, address, method, ...)
    if not ok then return nil, tostring(value) end
    return value, nil
end
return device
