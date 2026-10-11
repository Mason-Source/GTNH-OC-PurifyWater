--------------------------------------------------------------------------------
-- backend/app/rates.lua
--------------------------------------------------------------------------------
-- 【职责】"调度模式切换 + 速率模式配置"的**控制用例**：改内存 -> 落盘 -> 重判/重排/写日志
--   toggleMode()              主模式：阈值 <-> 速率
--   toggleEnforceThreshold()  速率模式子参数：是否仍受水位阈值约束（默认开）
--   setWeight(level, weight)  改某级权重（0..MAX 的整数；越界直接拒）
--   setT7Boost(value)         设 T7 增产倍率（只收 1 / 1.25 / 1.5 / 1.75 / 2 这五档）
-- 【不生效也照存】权重 / 增产在阈值模式下不算数，但照样写盘（切到速率模式就用）；
--   只有日志多一句"当前模式不生效，已保存待用"（判据 = system.effect()，与界面灰显同一份）。
-- 【不做什么】不算数（domain/rates）、不画界面、不碰机器、不判定能不能开
-- 【依赖】shared/{config,constants,logs,state}、store/{settings,rates_config}、
--         domain/mode、app/{plan,system}
-- 【被谁用】backend/api（命令入口）；Step 5 的界面按钮也走这里
--------------------------------------------------------------------------------

local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local logs         = require("shared.logs")
local state        = require("shared.state")

local settings     = require("backend.store.settings")
local rates_config = require("backend.store.rates_config")

local mode         = require("backend.domain.mode")

local plan         = require("backend.app.plan")
local system       = require("backend.app.system")

-- 不生效的配置照样保存：日志尾巴上这一句（只在"当前模式用不到它"时加）
local IDLE_NOTE    = "（当前模式不生效，已保存待用）"

local app          = {}

--- 变更后统一收尾：发布建议（模式切换/权重/倍率都会改建议）-> 忘掉旧方案 -> 审计 -> 重排
-- 【顺序】publish 必须在 audit 之前：审计（rate.audit）读的是发布出来的明细
-- @param reason string
local function afterChange(reason)
    system.publish()
    plan.forget()
    system.auditThresholds()
    system.requestPlan(reason)
end

--- 主模式切换（阈值 <-> 速率）：改内存 + 落盘 + 重判重排
-- @return string 新的模式 id
function app.toggleMode()
    local nextId = (state.system.mode == "rate") and "threshold" or "rate"
    state.system.mode = nextId

    local ok = settings.set("mode", nextId)
    logs.system(string.format("调度模式：%s%s", mode.labelOf(nextId),
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    afterChange("调度模式切换")
    return nextId
end

--- 速率模式子参数：是否受水位阈值约束（默认开）
-- @return boolean 新的取值
function app.toggleEnforceThreshold()
    state.system.enforceThreshold = not state.system.enforceThreshold

    local ok = settings.set("enforce_threshold", state.system.enforceThreshold)
    logs.system(string.format("速率模式：%s水位阈值约束%s",
        state.system.enforceThreshold and "受" or "不受",
        ok and "（已保存，下次启动沿用）" or "（保存失败，重启会回到默认）"))
    afterChange("阈值约束切换")
    return state.system.enforceThreshold
end

--- 改某级权重（0..MAX 的整数；越界/非整数直接拒）
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
        system.effect().weight and "" or IDLE_NOTE))
    afterChange("权重变更")
    return true, ""
end

--- 设 T7 增产倍率（只收 T7_BOOST_OPTIONS 里的档位；界面用选项键盘点即提交）
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
        system.effect().boost and "" or IDLE_NOTE))
    afterChange("T7 增产倍率变更")
    return true, ""
end

return app
