local energy = {}
local function bufferK(head)
    if head:find("wirelesstunnel", 1, true) then return 4000 end 
    if head:find("tunnel", 1, true) then return 24 end
    return nil
end
local function whole(x)
    return math.floor(x + 0.5)
end
function energy.powerOf(item, euMax)
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
    local voltage = 8 * (4 ^ tier)
    local nominal = voltage * amps
    if tunnel then
        local k = bufferK(head)
        if k and type(euMax) == "number" and euMax > 0 then
            local exact = euMax / k
            if exact ~= nominal then
                return whole(exact), string.format("激光仓限流至 %.0f A（最高 %.0f A）",
                    exact / voltage, amps)
            end
            return whole(exact)
        end
    end
    return whole(nominal)
end
return energy
