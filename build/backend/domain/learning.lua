local constants = require("shared.constants")
local state     = require("shared.state")
local learning  = {}
function learning.remember(level, parallel, success)
    if type(parallel) ~= "number" or parallel <= 0 then return false end
    state.write.learnSet(level, parallel, "measured", success)
    return true
end
function learning.forget(level)
    local function clear(lv)
        state.write.learnClear(lv)
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
        local learn = state.read.learn(lv)
        if learn and type(learn.parallel) == "number" and learn.parallel > 0
            and learn.source == "measured" then
            n = n + 1
        end
    end
    return n
end
return learning
