--------------------------------------------------------------------------------
-- frontend/theme.lua
--------------------------------------------------------------------------------
-- 【职责】配色方案 + "状态 -> 颜色/文案"的映射规则（颜色值不许散落在面板里）
-- 【不做什么】不读业务数据 —— 需要判断的地方由调用方传入布尔值
-- 【依赖】无
-- 【被谁用】frontend/widgets、frontend/panels/*、frontend/charts
--
-- 【来源】v2 的 theme.lua（实机调过的配色，直接搬过来复用）
--------------------------------------------------------------------------------

local theme      = {}

-- 主色板（0xRRGGBB）
theme.COLORS     = {
    BG                = 0x0d1117, -- 全局背景（深色）
    BORDER            = 0x1e3a8a, -- 常规边框（蓝）
    BORDER_ALERT      = 0x991b1b, -- 高级水优先模式边框（红）
    TEXT              = 0xe2e8f0, -- 常规文本
    TEXT_CYAN         = 0x38bdf8, -- 标题/强调
    TEXT_GREEN        = 0x22c55e, -- 正常/运行中
    TEXT_YELLOW       = 0xf59e0b, -- 待机/提示
    TEXT_RED          = 0xef4444, -- 异常/未部署
    TEXT_DISABLED     = 0x64748b, -- 只读/禁用文字

    BTN_BG            = 0x1e293b, -- 按钮底色
    BTN_BG_HOVER      = 0x334155, -- 按钮"激活"底色
    BTN_BG_DISABLED   = 0x111827, -- 禁用按钮底色
    BTN_PRIORITY_HIGH = 0x7f1d1d, -- 高级水优先按钮底色

    -- 进度条：底色浅绿 + 进度绿。状态由行内文字表达，条只表达"水位占参考线的比例"。
    BAR_BG            = 0x86efac, -- 进度条底（浅绿）
    BAR_FILL          = 0x22c55e, -- 进度条填充（绿）
    BAR_BG_EMPTY      = 0x450a0a, -- 进度条底（**一格都没填上**时用暗红，一眼看出这级没水）

    -- 运行周期条：蓝底蓝进度（与绿底绿进度的水位条区分）
    CYCLE_BG          = 0x1e293b, -- 未完成部分（深蓝灰，跟按钮底色一系）
    CYCLE_FILL        = 0x38bdf8  -- 已完成部分（亮蓝，跟标题同色系）
}

-- 日志行颜色：种类由 shared/logs 按**前缀**判出（logs.kindOf），面板不做关键字猜测式上色。
theme.LOG_COLORS = {
    warn     = 0xef4444, -- [警告] 异常 / 失败
    fix      = 0xf59e0b, -- [纠偏] 自动纠正
    schedule = 0x38bdf8, -- [调度] 调度与判定
    system   = 0xe2e8f0, -- [系统] 状态变化
    ui       = 0x64748b, -- [界面] 操作回执 / 被拒原因
    debug    = 0x64748b, -- [调试] debug 细节
    info     = 0xe2e8f0  -- 没前缀的普通行
}

--- 日志行颜色
-- @param kind string logs.kindOf() 的结果
-- @return number
function theme.logColor(kind)
    return theme.LOG_COLORS[kind] or theme.COLORS.TEXT
end

-- 图表辅助色
theme.CHART_GRID  = 0x2a3a5a
theme.CHART_AXIS  = 0x64748b
theme.CHART_WATER = 0x0ea5e9

-- "全部水量"模式下 8 条曲线各自的颜色（按等级 1..8）
theme.SERIES      = {
    0x38bdf8, -- T1 蓝
    0x22c55e, -- T2 绿
    0xf59e0b, -- T3 橙
    0xa855f7, -- T4 紫
    0xef4444, -- T5 红
    0x14b8a6, -- T6 青
    0xeab308, -- T7 黄
    0xf472b6  -- T8 粉
}

--- 某等级曲线的颜色
-- @param level number
-- @return number
function theme.seriesColor(level)
    return theme.SERIES[level] or theme.CHART_WATER
end

--- 面板边框色（高级水优先时红框提示）
-- @param highFirst boolean
-- @return number
function theme.borderColor(highFirst)
    return highFirst and theme.COLORS.BORDER_ALERT or theme.COLORS.BORDER
end

--- 系统状态一行（**只给短状态**，原因写日志）
-- 状态行只给短状态（硬件缺失 / 已锁定 / 自动调度中 / 已停机）：写超了不会自动清理
--   （面板是局部重绘，不会因超长而整屏刷新），多余的字会糊到邻面板；详细原因看系统日志。
-- 没有"已暂停"：只有"在跑"与"停了等人"两种，后者一律叫已锁定。
-- @param system table api.read.system() 的返回
-- @param hardware table api.read.hardware() 的返回
-- @return string 文本
-- @return number 颜色
function theme.systemStatus(system, hardware)
    local missing = hardware and hardware.missing or {}
    if #missing > 0 then
        return "硬件缺失", theme.COLORS.TEXT_RED
    end
    if system.locked then
        return "已锁定", theme.COLORS.TEXT_RED
    end
    if system.running then
        return "自动调度中", theme.COLORS.TEXT_GREEN
    end
    return "已停机", theme.COLORS.TEXT_YELLOW
end

return theme
