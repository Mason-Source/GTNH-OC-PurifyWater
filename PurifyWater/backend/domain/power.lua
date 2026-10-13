--------------------------------------------------------------------------------
-- backend/domain/power.lua
--------------------------------------------------------------------------------
-- 【职责】并行 <-> 功率唯一换算处：单台并行、总并行、总功耗
-- 【不做什么】不读组件、不下发（actuator）、不写文件、不含建议公式（modes/*）
-- 【依赖】shared/constants、shared/state
-- 【被谁用】domain/rules（水位线）、domain/allocator（贪心预算）、app/watch（刷新）、前端显示
--
-- 关键约定：
--   可用功率 = facts.powerMax（能量仓折算最大值）× 利用因子%（state.read.powerAll 现算）；
--   一次调度总预算来自它，allocator 逐级扣减。
--   建议值只读不夹（夹取在各模式 publish）；实测值从不夹。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")


local power     = {}

--- 该等级"采用的单台并行" + 来源
-- 优先级：本轮学习并行（连续 N 个运行周期确认过的 measured） > 建议值（suggest）
-- @param level number
-- @return number parallel
-- @return string "measured"|"suggest"
function power.adopted(level)
    local learn = state.read.learn(level)
    if learn and type(learn.parallel) == "number" and learn.parallel > 0 then
        return learn.parallel, "measured"
    end
    return power.suggest(level), "suggest"
end

--- 该等级总并行 = 单台并行 × 台数
-- @param level number
-- @return number
function power.levelParallel(level)
    return power.adopted(level) * math.max(0, state.read.plant(level).deployed or 0)
end

--- 该等级总功耗 = 总并行 × 单并行功耗
-- @param level number
-- @return number
function power.levelPower(level)
    return power.levelParallel(level) * (constants.POWER_LEVELS[level] or 0)
end

--- 建议并行（每台）：读 state 发布值。
-- 算账只在受控点做一次并发布，读侧不再触发计算。
-- @param level number
-- @return number
function power.suggest(level)
    return state.read.suggest(level)
end

--- 每台建议并行整数向量（比较基线）。
-- 只比整数建议，不看实测/学习值。
-- @return table 8 项整数数组
function power.suggestVector()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = math.floor(tonumber(state.read.suggest(level)) or 0)
    end
    return out
end

--- 重置本轮剩余预算（allocator 逐级扣减；每次调度前调一次）
function power.refresh()
    state.write.setBudget(state.read.powerAll())
end

return power
