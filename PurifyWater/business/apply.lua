-- 计划 -> 机器命令清单：纯数据，不调用组件。
local constants = require("shared.constants")

local apply = {}

function apply.commands(previous, desired, machinesByLevel, forceAll)
    local commands, levels = {}, {}
    for level = 1, constants.LEVEL_COUNT do
        local want = (desired or {})[level] == true
        if forceAll == true or ((previous or {})[level] == true) ~= want then
            levels[#levels + 1] = level
            for _, machine in ipairs((machinesByLevel or {})[level] or {}) do
                commands[#commands + 1] = {
                    level = level,
                    address = machine.address,
                    want = want,
                }
            end
        end
    end
    return commands, levels
end

function apply.shutdown(machinesByLevel)
    local commands = {}
    for level = 1, constants.LEVEL_COUNT do
        for _, machine in ipairs((machinesByLevel or {})[level] or {}) do
            commands[#commands + 1] = {
                level = level,
                address = machine.address,
                want = false,
            }
        end
    end
    return commands
end

return apply