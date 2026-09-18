local energy = {}
function energy.powerOf(item)
    local name = tostring(item and item.name or "")
    local tier = tonumber(name:match("tier%.(%d+)"))
    if not tier then return 0 end
    local head   = name:match("^hatch%.([^.]+)") or ""
    local amps   = 1
    local multi  = tonumber(head:match("multi(%d+)"))
    local tunnel = tonumber(head:match("tunnel(%d+)"))
    if multi then
        amps = multi
    elseif tunnel then
        amps = 64 * (4 ^ tunnel)
    end
    return 8 * (4 ^ tier) * amps
end
return energy
