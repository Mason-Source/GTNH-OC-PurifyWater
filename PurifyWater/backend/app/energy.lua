--------------------------------------------------------------------------------
-- backend/app/energy.lua
--------------------------------------------------------------------------------
-- 【职责】能源仓利用因子用例：设置 1-100% -> 改内存 + 落盘 + 发功率事实
-- 【不做什么】不读组件、不算功率（那是 hardware/energy 与 jobs T1）
-- 【依赖】core/scheduler、shared/*、store/settings、domain/power
-- 【被谁用】backend/api（命令入口）
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local state     = require("shared.state")
local scheduler = require("core.scheduler")

local settings  = require("backend.store.settings")
local power     = require("backend.domain.power")

local app       = {}

--- 设置能源仓利用因子（%）：可用功率 = 折算最大功率 × 因子
-- @param value number|string 1-100 整数
-- @return boolean ok
-- @return string 说明
function app.setFactor(value)
    local min, max = CONFIG.ENERGY.FACTOR_MIN, CONFIG.ENERGY.FACTOR_MAX
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < min or value > max then
        return false, string.format("利用因子需为 %d-%d 的整数（%%）", min, max)
    end
    if value == state.read.energyFactor() then return true, "" end

    local before = state.read.powerAll()
    state.write.setEnergyFactor(value)
    power.refresh() -- 预算跟着新可用功率重置（避免"已用"拿旧账算出负数）

    local ok = settings.set(CONFIG.ENERGY.FACTOR_KEY, value)
    logs.system(string.format("能源仓利用因子：%d%%%s", value,
        ok and "" or "（保存失败，重启回到默认）"))

    local after = state.read.powerAll()
    if before ~= after then
        scheduler.emit("power_changed", { from = before, to = after, note = "利用因子" })
    end
    return true, ""
end

return app
