--------------------------------------------------------------------------------
-- backend/app/rates.lua
--------------------------------------------------------------------------------
-- 【职责】模式切换 + 速率配置控制：改内存 -> 落盘 -> 发事实事件；事件入口做发布/审计/重排
-- 【不做什么】不算数（domain/rates）、不画界面、不碰机器
-- 【依赖】core/scheduler、shared/*、store/{settings,rates_config}、domain/mode、app/{plan,system}
-- 【被谁用】backend/api（命令入口）、backend/handlers（事件入口）
--
-- 不生效也照存（阈值模式下照写盘），日志加"当前模式不生效，已保存待用"。
--------------------------------------------------------------------------------

local scheduler    = require("core.scheduler")

local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local logs         = require("shared.logs")
local state        = require("shared.state")

local settings     = require("backend.store.settings")
local rates_config = require("backend.store.rates_config")

local mode         = require("backend.domain.mode")

local plan         = require("backend.app.plan")
local system       = require("backend.app.system")

-- 不生效配置照样保存的日志尾巴
local IDLE_NOTE    = "（当前模式不生效，已保存待用）"

local app          = {}

--- 变更后统一收尾：发布 -> 忘掉旧方案 -> 审计 -> 重排
-- publish 必须最先：审计读发布明细、requestPlan 里的基线比较都在 publish 后
-- @param reason string
local function afterSuggestChange(reason)
    system.publish()
    plan.forget()
    system.auditThresholds()
    system.requestPlan(reason)
end

--- 主模式切换：改内存 + 落盘 + 重判重排
-- @return string 新的模式 id
function app.toggleMode()
    local nextId = (state.read.mode() == "rate") and "threshold" or "rate"
    state.write.setMode(nextId)

    local ok = settings.set("mode", nextId)
    logs.system(string.format("调度模式：%s%s", mode.labelOf(nextId),
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    scheduler.emit("mode_changed", { mode = nextId })
    return nextId
end

--- 阈值约束开关
-- @return boolean 新的取值
function app.toggleEnforceThreshold()
    state.write.setEnforce(not state.read.enforceThreshold())

    local ok = settings.set("enforce_threshold", state.read.enforceThreshold())
    logs.system(string.format("速率模式：%s水位阈值约束%s",
        state.read.enforceThreshold() and "受" or "不受",
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    scheduler.emit("enforce_changed", { on = state.read.enforceThreshold() })
    return state.read.enforceThreshold()
end

--- 改单级权重（0..MAX 整数）
-- @param level number
-- @param weight number
-- @return boolean ok
-- @return string 说明（失败原因）
function app.setWeight(level, weight)
    level, weight = tonumber(level), tonumber(weight)
    if not level or level < 1 or level > constants.LEVEL_COUNT then
        return false, "等级无效"
    end
    if not weight or weight < 0 or weight > CONFIG.RATES.MAX_WEIGHT
        or weight ~= math.floor(weight) then
        return false, string.format("权重需为 0-%d 的整数", CONFIG.RATES.MAX_WEIGHT)
    end

    local ok, err = rates_config.setWeight(level, weight)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end

    logs.system(string.format("%s 权重 = %d%s", constants.levelLabel(level), weight,
        system.effectiveConfig().weight and "" or IDLE_NOTE))
    scheduler.emit("rates_changed", { why = "权重变更" })
    return true, ""
end

--- 设 T7 增产倍率（只收档位表里的值）
-- @param value number|string
-- @return boolean ok
-- @return string 说明（失败原因）
function app.setT7Boost(value)
    value = tonumber(value)

    local options, matched = constants.T7_BOOST_OPTIONS, false
    for _, option in ipairs(options) do
        if option == value then matched = true break end
    end
    if not matched then
        return false, string.format("增产倍率只能是 %s", table.concat(options, " / "))
    end

    local ok, err = rates_config.setBoost(value)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end

    logs.system(string.format("T7 增产倍率：×%s%s", tostring(value),
        system.effectiveConfig().boost and "" or IDLE_NOTE))
    scheduler.emit("rates_changed", { why = "T7 增产倍率变更" })
    return true, ""
end

--- 设 T1/T2 是否启用回流数据收集
-- @param level number
-- @param enabled boolean
-- @return boolean ok
-- @return string 说明
function app.setReflux(level, enabled)
    level = tonumber(level)
    if level ~= 1 and level ~= 2 then return false, "回流数据收集只支持 T1/T2" end
    if type(enabled) ~= "boolean" then return false, "开关值无效" end

    local ok, err = rates_config.setReflux(level, enabled)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end

    logs.system(string.format("%s 回流数据收集：%s%s", constants.levelLabel(level),
        enabled and "开" or "关",
        system.effectiveConfig().boost and "" or IDLE_NOTE))
    scheduler.emit("rates_changed", { why = "回流数据收集变更" })
    return true, ""
end

--- 设 T6 是否使用双锂数据收集（基础成功率 0.8 -> 0.9）
-- @param enabled boolean
-- @return boolean ok
-- @return string 说明
function app.setT6DualLithium(enabled)
    if type(enabled) ~= "boolean" then return false, "开关值无效" end

    local ok, err = rates_config.setT6DualLithium(enabled)
    if not ok then return false, "写配置失败（settings.txt）：" .. tostring(err) end

    logs.system(string.format("T6紫外 双锂数据收集：%s%s", enabled and "开" or "关",
        system.effectiveConfig().boost and "" or IDLE_NOTE))
    scheduler.emit("rates_changed", { why = "T6 双锂数据收集变更" })
    return true, ""
end

-- 事件入口：配置类事实 -> 发布 / 审计 / 重排（publish 必须最先）

--- 主模式切换：发布实现整套换掉
function app.onModeChanged()
    afterSuggestChange("调度模式切换")
end

--- 权重 / T7 倍率变化（命令或启动读入两条来源汇到这里）
function app.onRatesChanged(payload)
    logs.debug(tostring(payload and payload.why or "速率配置已更新"))
    -- 生效性门：这两个输入只在速率模式生效；不生效只保存，不动运行时
    if not system.effectiveConfig().weight then return end
    afterSuggestChange(payload and payload.why or "权重变化")
end

--- 阈值约束开关：只影响判定（evaluate），不影响发布输入 -> 忘方案 + 重排
function app.onEnforceChanged()
    plan.forget()
    system.requestPlan("阈值约束切换")
end

return app
