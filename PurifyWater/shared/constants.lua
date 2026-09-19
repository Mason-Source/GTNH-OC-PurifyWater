--------------------------------------------------------------------------------
-- shared/constants.lua
--------------------------------------------------------------------------------
-- 【职责】整个工程「永不改变」的常量：等级映射、流体名、机器名、单并行功耗、电压档
-- 【不做什么】不含任何可调参数（那在 shared/config.lua），不含逻辑
-- 【依赖】无 —— 保证任何层都能安全 require
-- 【被谁用】shared/*、backend/*、frontend/*
--------------------------------------------------------------------------------

local constants                   = {}

-- ============================ 版本戳 ============================
-- OC 的 shell 会缓存已加载的模块：只重启程序不一定拿到新代码。
-- 启动日志与 last_run 痕迹都写它，换完文件即可确认跑的是哪一份；改了需重启生效的东西就抬号。
-- 跑 `--debug` 时显示成 `vX.Y-debug`：后缀在 `core/bootstrap.version()` 里拼（常量本身只有号）。
constants.CODE_VERSION            = "v4.2"

-- 等级：1~8 级净水单元；0 级保留给净水主机
constants.LEVEL_COUNT             = 8
constants.HOST_LEVEL              = 0

-- ============================ 水位/并行 ============================
constants.STOCK_PER_PARALLEL      = 1000 -- 每并行预留的水量（mB）
constants.OPEN_RESERVE_MULTIPLIER = 5    -- "5 倍水位线" = 5 × 该级总并行 × STOCK_PER_PARALLEL

-- 各等级"单并行"功耗（EU/t）
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

-- ============================ 流体 / 机器 ============================
-- 等级 -> GT 流体注册名（净化水 grade1~grade8）
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

-- GT 机器名（getName() 的返回值）-> 等级；0 = 净水主机本体
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

-- 等级 -> 中文简称（日志与界面用；机器名是英文的，不能直接给用户看）
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

-- ============================ 电压档（GT 的 EU/t 档位表） ============================
-- GT 档位电压（EU/t）：ULV=8 … UXV=536,870,912。
-- 【豁免】当前无人引用，但**刻意保留** —— 不按"无引用即删"处理：
--   后续做"功率按电压档显示 / 按档位估产能 / 标注能源仓等级"时可直接用，不必再查表。
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

-- ============================ 键盘扫描码 ============================
-- `key_down` 的 char 载荷是**数字**（ASCII 码），某些布局/修饰键下可能为 0；扫描码（code）
-- 不受影响，用来兜底。
-- 【数据来源：实机观测，勿凭记忆改】
--   * Q：2026-09-16 实测 char=113 code=16 ✓（`data/last_run.txt` 里记的原始值）
--   * R：v2 实机验证过 code=19
--   * X：2026-09-27 实机（char=120 code=45）
--   * **P / T 没有条目**：只靠 char 识别（实测正常）；要补就实测后再写，不要猜。
--   【ENTER / ESCAPE / BACKSPACE 已删】阈值改用配置页虚拟键盘输入，物理键盘不进输入框。
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
