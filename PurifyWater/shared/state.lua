--------------------------------------------------------------------------------
-- shared/state.lua
--------------------------------------------------------------------------------
-- 【职责】**内存数据的唯一容器**：硬件快照、并行确认器、调度意图、系统状态、曲线、脏标记
-- 【不做什么】不含任何逻辑（判断、计算、IO 都不在）——一张表 + 几个访问器
-- 【依赖】shared/constants
-- 【被谁用】backend/hardware（写快照）、backend/domain（读快照算）、frontend（只读）
-- 【对应盘上的数据】backend/store/*（内存 -> 盘只有 persist 一条路）
--------------------------------------------------------------------------------

local constants = require("shared.constants")

local state = {}

-- ============================ 硬件快照（由 backend/hardware 写） ============================
-- plants[level] = {
--     deployed = number,          -- 在册台数
--     switch   = true|false|nil,  -- 全开 / 全关 / nil（混合态**或有读不到**——界面显示 ?）
--     lastSwitch = true|false|nil, -- T3 最近一次读到的开关（**电平**：每轮观测都写，含 nil）
--     active   = number|nil,      -- 确认在跑的台数；nil = 有读不到的（**不等于 0**，界面显示 ?）
--     sample   = number|nil,      -- **当前并行**：本周期读到的在跑机器的**最低并行**（多台取最小；**未确认**）
--     success  = number|nil,      -- 本级**最小成功率**（多台取最小；最近一次采样）
--     parallel = number|nil,      -- **真实并行**：当前并行连续 N 个运行周期一致 -> tracker 确认 -> 写这里
--                                 --   （power.adopted 优先用它；没有它才拿建议值当种子）
--     source   = "measured"|"suggest"|nil,
--     openable = true|false|nil,  -- 可开启性判定结果（domain/rules 写）
--     forced   = true|false|nil,  -- 是否"强制开启"（水位低于 5 倍线）
--     reason   = string|nil       -- 没开的原因（给人看的一句话）
-- }
-- progress / progressMax：**只有主机（T0）这一行有**（T3 只读主机；各水厂周期同步，T1-8 不记进度）；界面画周期条用
state.plants = {}

-- fluids[level] = number（mB；**读不到按 0 记** —— T2 是唯一写入方，注册时就写过一次）
state.fluids = {}

-- 功率：all = 全厂可用（能量仓）｜budget = 本轮剩余（allocator 逐级扣减）
state.power = { all = 0, budget = 0 }

-- 并行确认器：tracker[address] = { progress, cycleValue, value, streak, samples, confirmed }（见 domain/tracker）
state.tracker = {}

-- 系统状态
-- 锁定分两级，字段只有一个；级别按"当前事实"判（不看进入锁定的历史）：
--   硬锁定   = 硬件缺失 / 主机开关关 —— 物理上做不到，界面按钮变灰（vm.startBlockedReason）
--   暂停锁定 = 其它（硬件变更、开关与意图不符）—— 按钮可点，点它就是手动恢复
-- 两者都不自动恢复，只能由用户点【启动系统】退出（system.start 里 unlock）。
state.system = {
    running    = false, -- 自动控制系统是否在跑
    locked     = false, -- 进过安全状态：**不自动恢复**（硬锁时界面按钮还会变灰）
    lockReason = nil,   -- 锁定原因（**只记第一条**：谁先出事谁是真因）
    priority   = "low"  -- "low" = 低级水优先 / "high" = 高级水优先
}

-- 曲线（界面用；盘上的历史见 store/history）
-- 只有采样点：报表页与小时/天聚合已删。
state.chart = { points = {} }

-- 无线广播状态（T7）：enabled = 总开关；frame = 分片帧号（接收端据此拼帧）；warned = 失败只报一次
state.net = { enabled = false, frame = 0, warned = nil }

-- 阈值 + 勾选（由 store/levels_config 从文件读入）：rules[level] = { threshold = number, enabled = boolean }
state.rules = {}

-- 已下发过的方案（避免重复下发同一套指令）
state.lastPlan = {}

-- 脏标记（persist 任务据此决定写不写盘）
state.dirty = {}

-- ============================ 访问器 ============================

--- 取某等级的快照（不存在就建一个空的）
-- @param level number 0 = 主机
-- @return table
function state.plant(level)
    local p = state.plants[level]
    if not p then
        p = { deployed = 0 }
        state.plants[level] = p
    end
    return p
end

--- 标脏：`state.markDirty("records")`
-- @param what string
function state.markDirty(what)
    state.dirty[what] = true
end

--- 某类数据是否脏
-- @param what string
-- @return boolean
function state.isDirty(what)
    return state.dirty[what] == true
end

--- 清除脏标记（成功写盘后调用）
-- @param what string
function state.clearDirty(what)
    state.dirty[what] = nil
end

--- 系统是否"在自动调度中"：在跑且未锁定
-- 全工程唯一的调度闸（没有"暂停"这类会自己消失的中间态：要么在跑，要么停了等人）：
--   * 所有"想调度"的入口先查它，**提前**放弃，免得白做一遍再被挡回来
--   * `plan.run` 开头再查一次，作最后一道保险
-- @return boolean
function state.isActive()
    return state.system.running == true and state.system.locked == false
end

--- 低级水优先 / 高级水优先的扫描顺序（两种模式**只差这一个顺序**）
-- @return table 等级数组
function state.priorityOrder()
    local order = {}
    if state.system.priority == "high" then
        for level = constants.LEVEL_COUNT, 1, -1 do order[#order + 1] = level end
    else
        for level = 1, constants.LEVEL_COUNT do order[#order + 1] = level end
    end
    return order
end

return state
