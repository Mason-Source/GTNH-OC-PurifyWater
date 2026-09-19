--------------------------------------------------------------------------------
-- backend/app/plan.lua
--------------------------------------------------------------------------------
-- 【职责】"调度"这一个动作的**全部流程**：刷功率 -> 算方案 -> 比对 -> 下发 -> 记日志
-- 【下发与对比分在两个周期】本周期只下发（actuator 登记 cmd）；T3 下一个周期读回开关，
--   由 app/watch 比对、drifted() 在下一轮调度里纠偏 —— **同一周期内不回读**。
-- 【依赖】domain/{power,allocator,actuator}、shared/{constants,state,logs,utils}
-- 【被谁用】jobs（T4 定时）、app/watch（事件触发）、app/system（启动时）
--
-- 【幂等】方案与 state.lastPlan 相同、且实测状态与方案一致 -> 什么都不做
--   （每 5 秒无脑下发 8 条指令既浪费，也会把归因搅乱）。
-- 【纠偏】方案没变、**没有待确认的下发**、但实测开关与方案不符（玩家在 GT 界面手动关过）
--   -> 强制重新下发。还挂着待确认记录的不符由 app/watch 报警（那才是"机器拒听"）。
-- v2 把"算"和"下发"散在 dispatch / actuator / unitScan 三处，
--   出现过"算了一套、下发另一套"；这里只有这一条路径。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local logs      = require("shared.logs")
local state     = require("shared.state")
local utils     = require("shared.utils")

local power     = require("backend.domain.power")
local allocator = require("backend.domain.allocator")
local actuator  = require("backend.domain.actuator")
local settings  = require("backend.store.settings")

local plan      = {}

-- 只提醒一次的哨兵（避免同一个警告每 5 秒刷一屏）
local warned    = {}

local function once(key, text)
    if warned[key] then return end
    warned[key] = true
    logs.append(text)
end

local function clearOnce(key)
    warned[key] = nil
end

--- 找出"实测开关与方案不符"的等级（纠偏用）
-- 只比"确实记过意图"的等级：lastPlan[level] 为 nil 有两种情形 ——
--   ① 还没跑过一轮调度；② 上一轮**没发出去**（actuator 报错，已被 plan.run 抹掉）。
--   两者都不算"实测与方案不符"：后者靠 isSame 不成立触发**重发**，不是纠偏。
-- 【只认"没人认领"的读数】还挂着待确认下发（state.cmd[level]）的等级**不在这里纠偏**：
--   那种不符是"我们发过、机器回的不是那个值"，由 app/watch 报警（停机 + 锁定）。
--   这里只处理"下发都已被确认过、开关却又变了"的情形 —— 玩家在 GT 界面动的，重发纠正。
-- @return number|nil level
local function drifted()
    for level = 1, constants.LEVEL_COUNT do
        local snap = state.plant(level)
        local want = state.lastPlan[level]
        if want ~= nil and (snap.deployed or 0) > 0 and snap.lastSwitch ~= nil
            and state.cmd[level] == nil and snap.lastSwitch ~= want then
            return level
        end
    end
    return nil
end

--- 跑一轮调度
-- @param reason string 触发原因（写日志）
-- @return boolean 是否真的下发了
function plan.run(reason)
    -- 最后一道闸：各入口已用 state.isActive() 提前拦过，这里防新增调用者漏拦
    if not state.isActive() then
        return false
    end

    power.refresh()
    local result = allocator.plan()

    if result.warn then
        once("noPower", result.warn)
    else
        clearOnce("noPower")
    end

    local fix = drifted()
    -- 【空意图表 = 还没跟机器对齐过】启动（或停机后重启）时 lastPlan 是空表：直接与算出来的
    --   方案比较，方案恰好全关时会被判成"一样"而短路 —— 机器上其实还是上一次运行留下的状态，
    --   必须先下发一次对齐。另外 drifted() 只比"记过意图"的等级，不会再把 nil 当成"意图=关"。
    local known = next(state.lastPlan) ~= nil
    if known and allocator.isSame(state.lastPlan, result.plan) and not fix then
        return false
    end

    local _, failed = actuator.apply(result.plan)
    state.lastPlan = result.plan

    -- 下发失败的等级**不算"意图已成立"**：否则下一周期 T3 读到旧值会判成"实测与意图不符"
    --   （先警告再 B 类停机锁定），而真因只是这一条没发出去。抹掉意图后：T3 侧 want == nil
    --   不报警；下一轮 isSame 不成立 -> 自动重试。
    local badNames = {}
    for level, err in pairs(failed or {}) do
        badNames[#badNames + 1] = constants.levelLabel(level)
        state.lastPlan[level]   = nil
        logs.debug(string.format("[调试] %s 下发失败：%s", constants.levelLabel(level), tostring(err)))
    end
    if #badNames > 0 then
        table.sort(badNames)
        logs.warn(string.format("%s 的开关没发出去（本轮不算数，下一轮再试）",
            table.concat(badNames, "、")))
    end

    logs.schedule(string.format("%s：%s ｜ 功率 %s / %s ｜ %s",
        tostring(reason or "-"),
        allocator.describe(result.plan),
        utils.formatShortNumber(result.used), utils.formatShortNumber(result.budget),
        actuator.describeReceipt()))

    if fix then
        logs.fix(string.format("%s 实测开关与方案不符，已重新下发", constants.levelLabel(fix)))
    end
    return true
end

--- 切换优先级（低级水优先 <-> 高级水优先），并立刻按新顺序重排
-- 运行模式是永久配置：切完立刻存盘、下次启动沿用；存盘失败不拦切换，只是重启回到默认值。
-- @return string 新的优先级
function plan.togglePriority()
    state.system.priority = (state.system.priority == "high") and "low" or "high"
    state.lastPlan        = {} -- 顺序变了，方案必须重算重下发
    local ok              = settings.set("priority", state.system.priority)
    logs.system(string.format("运行模式：%s%s",
        state.system.priority == "high" and "高级水优先" or "低级水优先",
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    -- 存盘照做；没在跑/已锁定则不发起调度
    if state.isActive() then plan.run("优先级切换") end
    return state.system.priority
end

--- 忘掉"已下发过什么"（停机/解锁/接管后必须调用，否则幂等判断会误判）
function plan.forget()
    state.lastPlan = {}
end

return plan
