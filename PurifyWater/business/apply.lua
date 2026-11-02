--------------------------------------------------------------------------------
-- PurifyWater/business/apply.lua
--
-- 定位：计划到机器开关命令的纯转换层。
-- 功能：比较前后等级计划并生成增量命令，或为停机生成全关命令。
-- 边界：只生成普通数据，不调用 setWorkAllowed，也不修改全局状态。
--------------------------------------------------------------------------------

local constants = require("shared.constants")

local apply = {}

--- 比较前后等级计划，返回需要下发的开关命令及发生变化的等级。
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

--- 为全部 T1-T8 已登记机器生成关闭命令。
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