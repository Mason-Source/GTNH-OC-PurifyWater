local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local state     = require("shared.state")
local scheduler = require("core.scheduler")
local settings  = require("backend.store.settings")
local power     = require("backend.domain.power")
local app       = {}
function app.setFactor(value)
    local min, max = CONFIG.ENERGY.FACTOR_MIN, CONFIG.ENERGY.FACTOR_MAX
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < min or value > max then
        return false, string.format("利用因子需为 %d-%d 的整数（%%）", min, max)
    end
    if value == state.read.energyFactor() then return true, "" end
    local before = state.read.powerAll()
    state.write.setEnergyFactor(value)
    power.refresh()
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
