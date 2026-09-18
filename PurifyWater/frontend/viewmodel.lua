--------------------------------------------------------------------------------
-- frontend/viewmodel.lua
--------------------------------------------------------------------------------
-- 【职责】把 `api.read.*` 变成**界面能直接画的数据**（含所有人话文案与格式化）
-- 【不做什么】不画图（panels/charts）、不发命令（input）、不碰后端别的模块
-- 【依赖】backend/api、shared/{utils,constants,config}、frontend/{theme,state}
-- 【被谁用】frontend/render（每帧取一次）
--
-- 这一层的用途：面板里不该出现 `if water < threshold then "低于阈值"` —— 判定属后端
--   （domain/rules）；这里只把后端给的理由翻成一行字、并算出进度条比例。
--
-- 【缓存】8 级 × 十几个字段 + 曲线统计，每帧重建在 OC 上是纯浪费：默认 0.25 秒重建一次
--   （CONFIG.UI.VIEW_REFRESH_SECONDS）；切页 / 命令后由 render 带 force=true 立刻重建。
-- 【省下的一块】曲线（按等级摊开，最多 CONFIG.CHART.POINTS 个点 × 8）只在总览页算。
--------------------------------------------------------------------------------

local utils     = require("shared.utils")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local computer  = require("computer")
local api       = require("backend.api")
local theme     = require("frontend.theme")
local fstate    = require("frontend.state")

local vm        = {}

-- 上次构建结果与时刻
---@type { data: table|nil, at: number }
local cache     = { data = nil, at = 0 }

--- 主机总开关 -> 一行文案 + 颜色
-- 主机只是个布尔（总控）：开关 = 允不允许各级水厂跑
-- @param sw boolean|nil
-- @return string 文本
-- @return number 颜色
local function hostText(sw)
    if sw == nil then return "读不到（检查主机）", theme.COLORS.TEXT_RED end
    if sw then return "已开启（允许运行）", theme.COLORS.TEXT_GREEN end
    return "已关闭（禁止运行）", theme.COLORS.TEXT_RED
end

--- kL 文本（阈值以 mB 存盘，界面一律按 kL 显示）：全量 + 三位逗号
-- 不直接整除：`levels.txt` 可以手改，若填了非整千的 mB，floor 会把 500 显示成 0
--   （看着像没设阈值）—— 所以有余数就保留小数。
-- @param milli number|nil
-- @return string
local function kiloText(milli)
    local kilo = (milli or 0) / 1000
    if kilo == math.floor(kilo) then return utils.formatNumber(kilo) end
    return (string.format("%.3f", kilo):gsub("0+$", ""):gsub("%.$", ""))
end

--- 构建视图数据
-- @param force boolean|nil true = 忽略缓存立刻重建
-- @return table
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
        logs     = api.read.logs(CONFIG.LOG.MAX_LINES) -- 内存里就这么多行（盘上那份更全）
    }

    -- 主数据：逐级补上"能直接画"的字段
    local machineTotal = 0
    for level = 1, constants.LEVEL_COUNT do
        local row          = data.levels[level]
        row.running        = (row.deployed > 0) and ((row.active or 0) > 0) or false
        row.waterText      = (row.water == nil) and "-" or utils.formatShortNumber(row.water)
        row.thresholdText  = utils.formatShortNumber(row.rule.threshold) -- 总览行里用短单位
        row.thresholdKText = kiloText(row.rule.threshold)                -- 配置页用：全量 + 逗号
        -- 当前并行 = 本周期传感器读到的在跑机器里的最低并行（多台取最小，未确认）
        row.sampleText     = row.sample and utils.formatShortNumber(row.sample) or "-"
        -- 陈旧标注：没在跑时这个值是上次运行留下的（不清零，只标注）
        row.sampleStale    = (row.active or 0) == 0
        -- 成功率：本级取最小（多台机器时在 T3 汇总）；没在跑就是上次的残留 -> 与并行一样标 (上次)
        local rateStale    = (row.sampleStale and row.success ~= nil) and "(上次)" or ""
        row.rateText       = string.format("成功率 %s%s",
            row.success and (tostring(row.success) .. "%") or "-", rateStale)
        row.suggestText    = utils.formatShortNumber(row.suggest or 0)
        row.switchText     = (row.deployed == 0) and "未部署"
            or ((row.switch == nil) and "读不到" or (row.switch and "开" or "关"))
        -- 台数与运行台数（界面一行里最短的表达）
        row.deployText     = string.format("×%d", row.deployed or 0)
        row.runText        = (row.deployed == 0) and "-"
            or ((row.active == nil) and "?" or (tostring(row.active) .. "/" .. tostring(row.deployed)))
        -- 水量 / 阈值（一个字段一次拼好：状态面板用，改格式只改这里）
        row.waterOfText    = string.format("%s / %s", row.waterText, row.thresholdText)
        machineTotal       = machineTotal + (row.deployed or 0)
        -- 进度条比例：优先用阈值，没勾选/阈值为 0 时用 5 倍线
        local base         = (row.rule.enabled and row.rule.threshold > 0) and row.rule.threshold
            or row.reserveLine
        row.ratio          = (base and base > 0) and math.min(1, (row.water or 0) / base) or 0
    end

    -- 汇总行文案（控制面板只画这几行，**一行一个字段**，面板不拼字符串）
    data.systemText, data.systemColor = theme.systemStatus(data.system, data.hardware)
    data.hostText, data.hostColor     = hostText(data.host.switch)
    local usedText                    = utils.formatShortNumber(data.power.used or 0)
    local allText                     = utils.formatShortNumber(data.power.all or 0)
    data.powerText                    = string.format("%s / %s EU/t", usedText, allText)
    data.meText                       = data.hardware.me and "已连接" or "未连接"
    data.meColor                      = data.hardware.me
        and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_RED
    data.machineText                  = string.format("%d 台（T1-T8）", machineTotal)

    -- 运行周期条：各级水厂周期同步 -> 只画主机那一个（T3 读回来的）；读不到就写"未运行"，
    --   不画一根假条。
    local hp, hm                      = data.host.progress, data.host.progressMax
    data.cycleRatio                   = (hp and hm and hm > 0) and math.max(0, math.min(1, hp / hm)) or 0
    data.cycleText                    = (hp and hm and hm > 0)
        and string.format("%d%%", math.floor(data.cycleRatio * 100 + 0.5)) or "未运行"

    -- 曲线：只在总览页算；窗口按"看得的是哪一档"取（全部 = 近 1 游戏日，单级 = 近 2 游戏日）
    if fstate.currentTab == "overview" then
        local days       = (fstate.chartLevel == 0)
            and (CONFIG.CHART.ALL_WINDOW_DAYS or 1) or (CONFIG.CHART.LEVEL_WINDOW_DAYS or 2)
        data.historyDays = days
        data.history     = api.read.history(days * (CONFIG.CHART.SECONDS_PER_GAME_DAY or 86400))
    end

    cache.data, cache.at = data, now
    return data
end

--- 让视图缓存立刻过期（命令执行后由 input 调用）
-- 命令可能改了后端状态；过期后下一帧重建 -> 面板指纹变化 -> 只重画变了的那几个面板。
function vm.expire()
    cache.data, cache.at = nil, 0
end

--- 现在不能启动系统的话，返回原因；能启动（或只是要停机）返回 nil
-- 唯一判据：控制面板按钮灰化、键盘 X 的拦截都走这里（否则会出现"按钮灰着、按 X 却能发命令"）。
-- 锁定分两级，灰不灰按**当前事实**判、不看 locked 标志：
--   * 硬锁定 = 硬件缺失 / 主机开关关 -> 物理上做不到，拦下（按钮变灰）
--   * 暂停锁定 = 其它原因（硬件变更、开关与意图不符）-> 不拦（点它就是手动恢复）
-- 按事实判的理由：缺件插回 / 主机打开后就该允许重新启用；按历史判会把人永久困在"点不了"。
-- @param data table vm.build() 的返回
-- @return string|nil 不能启动时的原因（人话）
function vm.startBlockedReason(data)
    if not data or not data.system then return "状态未知" end
    -- 运行中它代表"停机"，任何时候都允许，不拦
    if data.system.running then return nil end

    local missing = (data.hardware or {}).missing or {}
    if #missing > 0 then return "硬件缺失（" .. table.concat(missing, "/") .. "）" end
    if (data.host or {}).switch == false then return "净水主机停机" end
    return nil
end

return vm
