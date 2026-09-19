local utils     = require("shared.utils")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local computer  = require("computer")
local api       = require("backend.api")
local theme     = require("frontend.theme")
local fstate    = require("frontend.state")
local vm        = {}
local cache     = { data = nil, at = 0 }
local function hostText(sw)
    if sw == nil then return "读不到（检查主机）", theme.COLORS.TEXT_RED end
    if sw then return "已开启（允许运行）", theme.COLORS.TEXT_GREEN end
    return "已关闭（禁止运行）", theme.COLORS.TEXT_RED
end
local function kiloText(milli)
    local kilo = (milli or 0) / 1000
    if kilo == math.floor(kilo) then return utils.formatNumber(kilo) end
    return (string.format("%.3f", kilo):gsub("0+$", ""):gsub("%.$", ""))
end
function vm.build(force)
    local now  = computer.uptime()
    local ttl  = CONFIG.UI.VIEW_REFRESH_SECONDS or 0.25
    local done = cache.data
    if not force and done and (now - cache.at) < ttl then
        return done
    end
    local data = {
        system   = api.read.system(),
        hardware = api.read.hardware(),
        power    = api.read.power(),
        levels   = api.read.levels(),
        net      = api.read.net(),
        host     = api.read.host(),
        logs     = api.read.logs(CONFIG.LOG.MAX_LINES)
    }
    local machineTotal = 0
    for level = 1, constants.LEVEL_COUNT do
        local row          = data.levels[level]
        row.running        = (row.deployed > 0) and ((row.active or 0) > 0) or false
        row.waterText      = utils.formatShortNumber(row.water or 0)
        row.thresholdText  = utils.formatShortNumber(row.rule.threshold)
        row.thresholdKText = kiloText(row.rule.threshold)
        row.sampleText     = row.sample and utils.formatShortNumber(row.sample) or "-"
        row.sampleStale    = (row.active or 0) == 0
        local rateStale    = (row.sampleStale and row.success ~= nil) and "(上次)" or ""
        row.rateText       = string.format("成功率 %s%s",
            row.success and (tostring(row.success) .. "%") or "-", rateStale)
        row.suggestText    = utils.formatShortNumber(row.suggest or 0)
        row.switchText     = (row.deployed == 0) and "未部署"
            or ((row.switch == nil) and "读不到" or (row.switch and "开" or "关"))
        row.deployText     = string.format("×%d", row.deployed or 0)
        row.runText        = (row.deployed == 0) and "-"
            or ((row.active == nil) and "?" or (tostring(row.active) .. "/" .. tostring(row.deployed)))
        row.waterOfText    = string.format("%s / %s", row.waterText, row.thresholdText)
        machineTotal       = machineTotal + (row.deployed or 0)
        local base         = (row.rule.enabled and row.rule.threshold > 0) and row.rule.threshold
            or row.reserveLine
        row.ratio          = (base and base > 0) and math.min(1, (row.water or 0) / base) or 0
    end
    data.systemText, data.systemColor = theme.systemStatus(data.system, data.hardware)
    data.hostText, data.hostColor     = hostText(data.host.switch)
    local usedText                    = utils.formatShortNumber(data.power.used or 0)
    local allText                     = utils.formatShortNumber(data.power.all or 0)
    data.powerText                    = string.format("%s / %s EU/t", usedText, allText)
    data.meText                       = data.hardware.me and "已连接" or "未连接"
    data.meColor                      = data.hardware.me
        and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_RED
    data.machineText                  = string.format("%d 台（T1-T8）", machineTotal)
    local hp, hm                      = data.host.progress, data.host.progressMax
    data.cycleRatio                   = (hp and hm and hm > 0) and math.max(0, math.min(1, hp / hm)) or 0
    data.cycleText                    = (hp and hm and hm > 0)
        and string.format("%d%%", math.floor(data.cycleRatio * 100 + 0.5)) or "未运行"
    if fstate.currentTab == "overview" then
        local days       = (fstate.chartLevel == 0)
            and (CONFIG.CHART.ALL_WINDOW_DAYS or 1) or (CONFIG.CHART.LEVEL_WINDOW_DAYS or 2)
        data.historyDays = days
        data.history     = api.read.history(days * (CONFIG.CHART.SECONDS_PER_GAME_DAY or 86400))
    end
    cache.data, cache.at = data, now
    return data
end
function vm.expire()
    cache.data, cache.at = nil, 0
end
function vm.startBlockedReason(data)
    if not data or not data.system then return "状态未知" end
    if data.system.running then return nil end
    local missing = (data.hardware or {}).missing or {}
    if #missing > 0 then return "硬件缺失（" .. table.concat(missing, "/") .. "）" end
    if (data.host or {}).switch == false then return "净水主机停机" end
    return nil
end
return vm
