--------------------------------------------------------------------------------
-- backend/domain/power.lua
--------------------------------------------------------------------------------
-- 【职责】并行 <-> 功率 的**唯一换算处**：单台并行、总并行、总功耗；`suggest()` 转调当前调度模式
-- 【不做什么】不读组件（数字来自 state）、不下发（那是 actuator）、不写文件（store 的事）、
--            不含任何模式的建议公式（那在 backend/domain/modes/*）
-- 【依赖】shared/constants、shared/state
-- 【被谁用】domain/rules（水位线）、domain/allocator（贪心预算）、app/watch（刷新）、前端显示
--
-- 【关键约定】
--   state.power.all = 全厂可用功率（EU/t，来自能量仓）= 一次调度的总预算；
--   "低级水先吃预算、吃剩的留给高级水"就靠这个数字 + allocator 逐级扣减实现。
--   本文件是全工程唯一做"并行上限夹取"的地方，且只夹**建议值**；
--   实测值从不夹（实机 3000000 > 上限 2147483 属预期，界面不告警）。
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
    local snap = state.plant(level)
    if type(snap.parallel) == "number" and snap.parallel > 0 then
        return snap.parallel, "measured"
    end
    return power.suggest(level), "suggest"
end

--- 该等级总并行 = 单台并行 × 台数
-- @param level number
-- @return number
function power.levelParallel(level)
    return power.adopted(level) * math.max(0, state.plant(level).deployed or 0)
end

--- 该等级总功耗 = 总并行 × 单并行功耗
-- @param level number
-- @return number
function power.levelPower(level)
    return power.levelParallel(level) * (constants.POWER_LEVELS[level] or 0)
end

--- 建议并行（每台）—— **读 state 里的发布值**（由当前模式在受控点发布，见 mode.publish()）
-- 【为什么是读】建议并行是"模式算账"的产物：贵的算一次、发布到 state，读侧（界面/功耗估算/锁定基线）
--   一律只读，不再触发任何计算；阈值模式也走同一条路（数据结构统一）。
-- @param level number
-- @return number
function power.suggest(level)
    return state.plant(level).suggest or 0
end

--- 当前"每台建议并行"的整数向量（8 项，下标 = 等级）—— "建议变化 -> 锁定"的比较基线
-- 【只比整数建议】不看实测并行与学习值（玩家调机器并行的过程中实测值会变，建议不该跟着变）。
-- @return table 8 项整数数组
function power.suggestVector()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        out[level] = math.floor(tonumber(state.plant(level).suggest) or 0)
    end
    return out
end

--- 当前并行与建议值不一致的等级（**只找出"不一致"，不下结论**）
-- 【三个"并行"】
--   当前并行 = `state.plant(level).sample` —— T3 读到的本周期在跑机器的**最低并行**（多台取最小，未确认）
--   学习并行 = `state.plant(level).parallel` —— 当前并行**连续 N 个运行周期一致**后由 tracker 确认、
--              经 `learning.remember` 写入内存（来源标 "measured"，本次运行有效）
--   建议并行 = `power.suggest(level)` —— 公式推算；只在没有学习值时被 adopted 当种子
-- 【这里比的是「当前 vs 建议」】看机器**此刻**吃多少、跟公式认为它能吃多少差多少。
--   「学习并行 vs 建议」只反映本轮实测与公式推算的差异。
-- 【不一致不奇怪】机器行为与公式本来就不保证相等：可能没吃满、可能建议值被本级上限夹住、
--   也可能刚换能源仓在过渡。所以这里只给数字，文案由调用方写。
-- 【没读到过的不比】sample 为空（从未跑到过 / 刚开机）就没什么可比的。
-- @return table 数组 { { level = n, current = x, suggest = y }, ... }
function power.parallelMismatch()
    local out = {}
    for level = 1, constants.LEVEL_COUNT do
        local snap = state.plant(level)
        if snap.sample and (snap.deployed or 0) > 0 then
            local suggest = power.suggest(level)
            if snap.sample ~= suggest then
                out[#out + 1] = { level = level, current = snap.sample, suggest = suggest }
            end
        end
    end
    return out
end

--- 重置本轮剩余预算（allocator 逐级扣减；每次调度前调一次）
function power.refresh()
    state.power.budget = state.power.all or 0
end

return power
