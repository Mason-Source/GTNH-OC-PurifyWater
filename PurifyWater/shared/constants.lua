--------------------------------------------------------------------------------
-- shared/constants.lua
--------------------------------------------------------------------------------
-- 【职责】工程常量：等级映射、流体名、机器名、功耗、电压档
-- 【不做什么】不含可调参数（在 shared/config）、不含逻辑
-- 【依赖】无
-- 【被谁用】shared/*、backend/*、frontend/*
--------------------------------------------------------------------------------

local constants                   = {}

-- ---- 版本戳 ----
-- 启动日志与痕迹写版本戳；改动需重启生效时抬号。debug 后缀在 core/bootstrap 拼。
constants.CODE_VERSION            = "v5.0"

-- 等级：1~8 净水单元；0 = 净水主机
constants.LEVEL_COUNT             = 8
constants.HOST_LEVEL              = 0
constants.T3_LEVEL                = 3    -- 絮凝单元
constants.T4_LEVEL                = 4    -- pH 调节单元
constants.T5_LEVEL                = 5    -- 等离子加热单元
constants.T6_LEVEL                = 6    -- 紫外处理单元
constants.T7_LEVEL                = 7    -- 支持增产的等级
constants.T8_LEVEL                = 8    -- 萃取单元

-- ---- 水位/并行 ----
constants.STOCK_PER_PARALLEL      = 1000 -- 每并行预留水量（mB）
constants.OPEN_RESERVE_MULTIPLIER = 5    -- 保供线倍数

-- 单并行功耗（EU/t）
constants.POWER_LEVELS            = {
    [1] = 30720,
    [2] = 30720,
    [3] = 122880,
    [4] = 122880,
    [5] = 491520,
    [6] = 491520,
    [7] = 1966080,
    [8] = 7864320
}

-- ---- 速率模型（每并行每周期） ----
-- domain/rates 用：每并行吃 1000L 上一级、产 900L 本级；回流级多吃 90L 换 +15% 成功率。
-- 权重只取比例，绝对量级不影响结果。
constants.RATE_PRODUCE            = 900   -- 成功时产出本级水（L/并行/周期）
constants.RATE_CONSUME            = 1000  -- 消耗上一级水（L/并行/周期）
constants.RATE_REFLUX             = 90    -- 回流额外吃本级水（L/并行/周期）
constants.RATE_REFLUX_BONUS       = 0.15  -- 回流加成功率
constants.RATE_SUCCESS            = { 0.7, 0.8, 1, 1, 0.99, 0.8, 1, 1 } -- 基础成功率
constants.RATE_SUCCESS_DUAL_LITHIUM = 0.9 -- T6 使用双锂后的基础成功率
constants.RATE_REFLUX_LEVELS      = { [1] = true, [2] = true, [6] = true } -- 回流等级
constants.T7_BOOST_OPTIONS        = { 1, 1.25, 1.5, 1.75, 2 }             -- T7 增产档位

-- 单台并行上限（threshold/rate 共用）：T1 单独一档，T2~T8 同档
constants.PARALLEL_CAP_T1         = 2386092
constants.PARALLEL_CAP_OTHER      = 2147483

--- 某等级的单台并行上限
-- @param level number
-- @return number
function constants.parallelCap(level)
    return (level == 1) and constants.PARALLEL_CAP_T1 or constants.PARALLEL_CAP_OTHER
end

-- ---- 流体 / 机器 ----
-- 等级 -> GT 流体注册名
constants.FLUID_NAMES             = {
    [1] = "grade1purifiedwater",
    [2] = "grade2purifiedwater",
    [3] = "grade3purifiedwater",
    [4] = "grade4purifiedwater",
    [5] = "grade5purifiedwater",
    [6] = "grade6purifiedwater",
    [7] = "grade7purifiedwater",
    [8] = "grade8purifiedwater"
}

-- GT 机器名 -> 等级；0 = 净水主机
constants.MACHINE_NAMES           = {
    ["multimachine.purificationplant"]            = 0,
    ["multimachine.purificationunitclarifier"]    = 1,
    ["multimachine.purificationunitozonation"]    = 2,
    ["multimachine.purificationunitflocculator"]  = 3,
    ["multimachine.purificationunitphadjustment"] = 4,
    ["multimachine.purificationunitplasmaheater"] = 5,
    ["multimachine.purificationunituvtreatment"]  = 6,
    ["multimachine.purificationunitdegasifier"]   = 7,
    ["multimachine.purificationunitextractor"]    = 8
}

-- 等级中文简称（日志与界面）
constants.LEVEL_NAMES             = {
    [0] = "主机",
    [1] = "T1澄清",
    [2] = "T2臭氧",
    [3] = "T3絮凝",
    [4] = "T4调pH",
    [5] = "T5等离子",
    [6] = "T6紫外",
    [7] = "T7脱气",
    [8] = "T8萃取"
}

-- ---- 电压档（GT EU/t） ----
constants.VOLTAGE_TIERS           = {
    { name = "ULV", eu = 8 }, { name = "LV", eu = 32 },
    { name = "MV",  eu = 128 }, { name = "HV", eu = 512 },
    { name = "EV",  eu = 2048 }, { name = "IV", eu = 8192 },
    { name = "LuV", eu = 32768 }, { name = "ZPM", eu = 131072 },
    { name = "UV",  eu = 524288 }, { name = "UHV", eu = 2097152 },
    { name = "UEV", eu = 8388608 }, { name = "UIV", eu = 33554432 },
    { name = "UMV", eu = 134217728 }, { name = "UXV", eu = 536870912 },
    { name = "MAX", eu = 2147483640 }
}

-- ---- 键盘扫描码 ----
-- char 为 ASCII 码数字，部分布局为 0；扫描码兜底。
-- 扫描码来自实机观测；P/T 无条目，只靠 char。ENTER/ESC/BACKSPACE 已不用（虚拟键盘输入）。
constants.KEY_CODES               = {
    Q = 16,
    R = 19,
    X = 45
}

--- 等级短名（越界时回落到 "T<等级>"，避免日志里出现 nil）
-- @param level number
-- @return string
function constants.levelLabel(level)
    return constants.LEVEL_NAMES[level] or ("T" .. tostring(level))
end

return constants
