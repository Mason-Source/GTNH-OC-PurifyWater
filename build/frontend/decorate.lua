local utils     = require("shared.utils")
local constants = require("shared.constants")
local theme     = require("frontend.theme")
local M         = {}
local function hostText(sw)
    if sw == nil then return "读取失败", theme.COLORS.TEXT_RED end
    if sw then return "已开启", theme.COLORS.TEXT_GREEN end
    return "已关闭", theme.COLORS.TEXT_RED
end
local function kiloText(milli)
    local kilo = (milli or 0) / 1000
    if kilo == math.floor(kilo) then return utils.formatNumber(kilo) end
    return (string.format("%.3f", kilo):gsub("0+$", ""):gsub("%.$", ""))
end
function M.apply(data)
    local modeId     = data.system.mode or "threshold"
    data.runModeText = (modeId == "rate") and "速率调度" or "阈值调度"
    local machineTotal = 0
    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        if not row then
            row = { level = level, label = constants.levelLabel(level), deployed = 0,
                rule = { threshold = 0, effectiveThreshold = 0, enabled = false } }
            data.levels[level] = row
        end
        local pr = (data.produce and data.produce.levels and data.produce.levels[level]) or {}
        row.produceEnabled = pr.enabled == true
        if pr.state == "off" then
            row.produceText      = "[ ]"
            row.produceColor     = theme.COLORS.TEXT_DISABLED
            row.produceClickable = true
        elseif pr.state == "ok" then
            row.produceText      = "[√]"
            row.produceColor     = theme.COLORS.TEXT_GREEN
            row.produceClickable = true
        elseif pr.state == "blocked" then
            row.produceText      = "[!]"
            row.produceColor     = theme.COLORS.TEXT_YELLOW
            row.produceClickable = true
        else
            row.produceText      = "未就绪"
            row.produceColor     = theme.COLORS.TEXT_DISABLED
            row.produceClickable = true
        end
        row.label = row.label or constants.levelLabel(level)
        row.rule  = row.rule or { threshold = 0, effectiveThreshold = 0, enabled = false }
        row.running        = (row.deployed > 0) and ((row.active or 0) > 0) or false
        row.waterText      = utils.formatShortNumber(row.water or 0)
        row.thresholdText  = utils.formatShortNumber(row.rule.effectiveThreshold)
        row.thresholdKText = kiloText(row.rule.threshold)
        row.userThresholdText = utils.formatShortNumber(row.rule.userThreshold)
        row.thresholdOverridden = row.rule.thresholdOverridden == true
        row.sampleText     = row.sample and utils.formatShortNumber(row.sample) or "-"
        row.sampleStale    = (row.active or 0) == 0
        local rateStale    = (row.sampleStale and row.success ~= nil) and "（上次）" or ""
        row.rateText       = string.format("成功率 %s%s",
            row.success and (tostring(row.success) .. "%") or "-", rateStale)
        row.suggestText    = utils.formatShortNumber(row.suggest or 0)
        row.switchText     = (row.deployed == 0) and "未部署"
            or ((row.switch == nil) and "读取失败" or (row.switch and "开" or "关"))
        row.deployText     = string.format("×%d", row.deployed or 0)
        row.runText        = (row.deployed == 0) and "-"
            or ((row.active == nil) and "?" or (tostring(row.active) .. "/" .. tostring(row.deployed)))
        row.waterOfText    = string.format("%s / %s", row.waterText, row.thresholdText)
        machineTotal       = machineTotal + (row.deployed or 0)
        local base         = row.rule.effectiveThreshold
        row.ratio          = (base and base > 0) and math.min(1, (row.water or 0) / base) or 0
    end
    data.systemText, data.systemColor = theme.systemStatus(data.system, data.hardware, data.host)
    data.hostText, data.hostColor     = hostText(data.host.switch)
    local usedText                    = utils.formatShortNumber(data.power.used or 0)
    local allText                     = utils.formatShortNumber(data.power.all or 0)
    data.powerText                    = string.format("%s / %s EU/t", usedText, allText)
    data.meText                       = data.hardware.me and "已连接" or "未连接"
    data.meColor                      = data.hardware.me
        and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_RED
    data.machineText                  = string.format("%d 台（T1–T8）", machineTotal)
    local hp, hm                      = data.host.progress, data.host.progressMax
    data.cycleRatio                   = (hp and hm and hm > 0) and math.max(0, math.min(1, hp / hm)) or 0
    data.cycleText                    = (hp and hm and hm > 0)
        and string.format("%d%%", math.floor(data.cycleRatio * 100 + 0.5)) or "未运行"
    return data
end
function M.startBlockedReason(data)
    if not data or not data.system then return "状态未知" end
    if data.system.running then return nil end
    local missing = (data.hardware or {}).missing or {}
    if #missing > 0 then return "硬件缺失（" .. table.concat(missing, "/") .. "）" end
    if (data.host or {}).switch == false then return "净水主机未开机" end
    return nil
end
return M
