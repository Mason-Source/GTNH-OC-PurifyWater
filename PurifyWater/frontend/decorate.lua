--------------------------------------------------------------------------------
-- frontend/decorate.lua
--------------------------------------------------------------------------------
-- 【职责】把"原始数据"补成面板能直接画的形状（文案 / 颜色 / 比例）——纯函数
-- 【不做什么】不取数（主端 viewmodel / 镜像端收帧各管各的）、不画图、不发命令
-- 【依赖】shared/{utils,constants}、frontend/theme
-- 【被谁用】frontend/viewmodel（主端）、monitor.lua（镜像端复用同一套总览面板）
--------------------------------------------------------------------------------

local utils     = require("shared.utils")
local constants = require("shared.constants")
local theme     = require("frontend.theme")

local M         = {}

--- 主机总开关 -> 一行文案 + 颜色
-- @param sw boolean|nil
-- @return string 文本
-- @return number 颜色
local function hostText(sw)
    if sw == nil then return "读取失败", theme.COLORS.TEXT_RED end
    if sw then return "已开启", theme.COLORS.TEXT_GREEN end
    return "已关闭", theme.COLORS.TEXT_RED
end

--- kL 文本（阈值以 mB 存盘，界面按 kL 显示）
-- 非整千 mB 保留小数，避免 floor 显示成 0。
-- @param milli number|nil
-- @return string
local function kiloText(milli)
    local kilo = (milli or 0) / 1000
    if kilo == math.floor(kilo) then return utils.formatNumber(kilo) end
    return (string.format("%.3f", kilo):gsub("0+$", ""):gsub("%.$", ""))
end

--- 补展示字段（就地改 data）
-- @param data table 形状同 api.read.*（system/hardware/power/levels/host；镜像端由快照摆出）
-- @return table
function M.apply(data)
    -- 只留模式名；子参数在模式行按钮上
    local modeId     = data.system.mode or "threshold"
    data.runModeText = (modeId == "rate") and "速率调度" or "阈值调度"

    -- 主数据：逐级补上"能直接画"的字段
    local machineTotal = 0
    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        if not row then
            row = { level = level, label = constants.levelLabel(level), deployed = 0,
                rule = { threshold = 0, effectiveThreshold = 0, enabled = false } }
            data.levels[level] = row
        end
        -- 制作自动化（配置表那一列）：未实现等级画 - 且禁止点入；已实现等级四态可点。
        -- 镜像端无此域 -> 同样画 -。
        local pr = (data.produce and data.produce.levels and data.produce.levels[level]) or {}
        row.produceEnabled = pr.enabled == true
        if pr.implemented ~= true then
            row.produceText      = "-"
            row.produceColor     = theme.COLORS.TEXT_DISABLED
            row.produceClickable = false
        elseif pr.state == "off" then
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
        row.waterText      = utils.formatShortNumber(row.water or 0)     -- 水位恒为数字（读不到=0）
        -- 总览/详情用实际执行阈值；配置页继续显示用户原始阈值
        row.thresholdText  = utils.formatShortNumber(row.rule.effectiveThreshold)
        row.thresholdKText = kiloText(row.rule.threshold)
        row.userThresholdText = utils.formatShortNumber(row.rule.userThreshold)
        row.thresholdOverridden = row.rule.thresholdOverridden == true
        -- 当前并行 = 本周期最低读数（多台取最小，未确认）
        row.sampleText     = row.sample and utils.formatShortNumber(row.sample) or "-"
        -- 陈旧标注：没在跑时值为上次残留
        row.sampleStale    = (row.active or 0) == 0
        -- 成功率：本级最小；没在跑时为上次残留，同样标注
        local rateStale    = (row.sampleStale and row.success ~= nil) and "（上次）" or ""
        row.rateText       = string.format("成功率 %s%s",
            row.success and (tostring(row.success) .. "%") or "-", rateStale)
        row.suggestText    = utils.formatShortNumber(row.suggest or 0)
        row.switchText     = (row.deployed == 0) and "未部署"
            or ((row.switch == nil) and "读取失败" or (row.switch and "开" or "关"))
        -- 台数与运行台数（最短表达）
        row.deployText     = string.format("×%d", row.deployed or 0)
        row.runText        = (row.deployed == 0) and "-"
            or ((row.active == nil) and "?" or (tostring(row.active) .. "/" .. tostring(row.deployed)))
        -- 水量/阈值（一次拼好，状态面板用）
        row.waterOfText    = string.format("%s / %s", row.waterText, row.thresholdText)
        machineTotal       = machineTotal + (row.deployed or 0)
        -- 进度条按实际执行阈值；本级自身 N 倍线只用于上一级供料检查
        local base         = row.rule.effectiveThreshold
        row.ratio          = (base and base > 0) and math.min(1, (row.water or 0) / base) or 0
    end

    -- 汇总行文案（一行一个字段）
    data.systemText, data.systemColor = theme.systemStatus(data.system, data.hardware, data.host)
    data.hostText, data.hostColor     = hostText(data.host.switch)
    local usedText                    = utils.formatShortNumber(data.power.used or 0)
    local allText                     = utils.formatShortNumber(data.power.all or 0)
    data.powerText                    = string.format("%s / %s EU/t", usedText, allText)
    data.meText                       = data.hardware.me and "已连接" or "未连接"
    data.meColor                      = data.hardware.me
        and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_RED
    data.machineText                  = string.format("%d 台（T1–T8）", machineTotal)

    -- 周期条只画主机（各级同步）；读取失败写未运行。
    local hp, hm                      = data.host.progress, data.host.progressMax
    data.cycleRatio                   = (hp and hm and hm > 0) and math.max(0, math.min(1, hp / hm)) or 0
    data.cycleText                    = (hp and hm and hm > 0)
        and string.format("%d%%", math.floor(data.cycleRatio * 100 + 0.5)) or "未运行"

    return data
end

--- 不能启动时的原因；能启动返回 nil（按钮灰化与 X 拦截共用此判据）
-- 硬件未就绪（缺件/主机关）拦下；等待用户处理不拦。按当前事实判，不按历史。
-- @param data table（形状同 viewmodel.build 的返回）
-- @return string|nil 不能启动时的原因（人话）
function M.startBlockedReason(data)
    if not data or not data.system then return "状态未知" end
    -- 运行中它代表"停机"，任何时候都允许，不拦
    if data.system.running then return nil end

    local missing = (data.hardware or {}).missing or {}
    if #missing > 0 then return "硬件缺失（" .. table.concat(missing, "/") .. "）" end
    if (data.host or {}).switch == false then return "净水主机未开机" end
    return nil
end

return M
