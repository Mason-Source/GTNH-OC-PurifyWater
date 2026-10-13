--------------------------------------------------------------------------------
-- backend/app/plan.lua
--------------------------------------------------------------------------------
-- 【职责】调度全流程：刷功率 -> 算方案 -> 比对 -> 下发 -> 记日志
-- 【依赖】domain/{power,allocator,actuator}、shared/*
-- 【被谁用】jobs（T4）、app/watch、app/system
--
-- 下发只由两件事驱动：方案变、或尚未与机器对齐；实测不符不发（交 app/watch）。
-- 幂等：方案与 lastPlan 相同则不做。
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

-- 只提醒一次
local warned    = {}

local function once(key, text)
    if warned[key] then return end
    warned[key] = true
    logs.append(text)
end

local function clearOnce(key)
    warned[key] = nil
end

--- 跑一轮调度
-- 方案变、或尚未与机器对齐才下发；实测不符不在此处理（app/watch）。
-- @param reason string 触发原因（写日志）
-- @return boolean 是否真的下发了
function plan.run(reason)
    -- 最后一道闸：入口已拦，这里防漏
    if not state.read.running() then
        return false
    end

    power.refresh()
    local result = allocator.plan()

    if result.warn then
        once("noPower", result.warn)
    else
        clearOnce("noPower")
    end

    -- 【空意图表 = 还没跟机器对齐过】启动（或停机后重启）时 lastPlan 是空表：直接与算出来的
    --   方案比较，方案恰好全关时会被判成"一样"而短路 —— 机器上其实还是上一次运行留下的状态，
    --   必须先下发一次对齐。
    local known = next(state.read.lastPlan()) ~= nil
    if known and allocator.isSame(state.read.lastPlan(), result.plan) then
        return false
    end

    local _, failed = actuator.apply(result.plan)
    state.write.setLastPlan(result.plan)

    -- 下发失败的等级**不算"意图已成立"**：否则下一周期 T3 读到旧值会判成"偏离方案"
    --   （人工改动 -> 停会话 + 等待用户），而真因只是这一条没发出去。抹掉之后：T3 侧 want == nil
    --   不判；下一轮 isSame 不成立 -> 自动重试。
    local badNames = {}
    for level, err in pairs(failed or {}) do
        badNames[#badNames + 1] = constants.levelLabel(level)
        state.write.deleteLastPlanLevel(level)
        logs.debug(string.format("%s 下发失败：%s", constants.levelLabel(level), tostring(err)))
    end
    if #badNames > 0 then
        table.sort(badNames)
        logs.warn(string.format("%s 下发失败，下一轮重试",
            table.concat(badNames, "、")))
    end

    logs.schedule(string.format("%s：%s ｜ 功率 %s / %s ｜ %s",
        tostring(reason or "-"),
        allocator.describe(result.plan),
        utils.formatShortNumber(result.used), utils.formatShortNumber(result.budget),
        actuator.describeReceipt()))

    return true
end

--- 切换优先级（低级水优先 <-> 高级水优先）
-- 运行模式是永久配置：切完立刻存盘、下次启动沿用；存盘失败不拦切换，只是重启回到默认值。
-- @return string 新的优先级
function plan.togglePriority()
    state.write.setPriority((state.read.priority() == "high") and "low" or "high")
    state.write.clearPlan() -- 顺序变了，方案必须重算重下发
    local ok              = settings.set("priority", state.read.priority())
    logs.system(string.format("运行模式：%s%s",
        state.read.priority() == "high" and "高级水优先" or "低级水优先",
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    return state.read.priority()
end

--- 忘掉已下发方案（停会话后必调）
function plan.forget()
    state.write.clearPlan()
end

return plan
