local constants = require("shared.constants")
local state     = require("shared.state")
local learning  = {}
function learning.remember(level, parallel, success)
    if type(parallel) ~= "number" or parallel <= 0 then return false end
    local snap    = state.plant(level)
    snap.parallel = parallel
    snap.success  = success or snap.success
    snap.source   = "measured"
    return true
end
function learning.forget(level)
    local function clear(lv)
        local snap = state.plant(lv)
        snap.parallel, snap.source = nil, nil
    end
    if level then
        clear(level)
    else
        for lv = 1, constants.LEVEL_COUNT do clear(lv) end
    end
end
function learning.forgetAll()
    learning.forget(nil)
end
function learning.count()
    local n = 0
    for lv = 1, constants.LEVEL_COUNT do
        local snap = state.plant(lv)
        if type(snap.parallel) == "number" and snap.parallel > 0
            and snap.source == "measured" then
            n = n + 1
        end
    end
    return n
end
return learning
