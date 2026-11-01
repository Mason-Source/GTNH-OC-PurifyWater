-- 固定等级与机器映射；运行期可调项放 config。
local constants = {
    CODE_VERSION = "v6.0.1",
    LEVEL_COUNT = 8,
    HOST_LEVEL = 0,
    T3_LEVEL = 3,
    T4_LEVEL = 4,
    T5_LEVEL = 5,
    T6_LEVEL = 6,
    T7_LEVEL = 7,
    T8_LEVEL = 8,
}

constants.MACHINE_NAMES = {
    ["multimachine.purificationplant"] = 0,
    ["multimachine.purificationunitclarifier"] = 1,
    ["multimachine.purificationunitozonation"] = 2,
    ["multimachine.purificationunitflocculator"] = 3,
    ["multimachine.purificationunitphadjustment"] = 4,
    ["multimachine.purificationunitplasmaheater"] = 5,
    ["multimachine.purificationunituvtreatment"] = 6,
    ["multimachine.purificationunitdegasifier"] = 7,
    ["multimachine.purificationunitextractor"] = 8,
}

constants.VOLTAGE_TIERS = {
    { name = "ULV", eu = 8 }, { name = "LV", eu = 32 },
    { name = "MV",  eu = 128 }, { name = "HV", eu = 512 },
    { name = "EV",  eu = 2048 }, { name = "IV", eu = 8192 },
    { name = "LuV", eu = 32768 }, { name = "ZPM", eu = 131072 },
    { name = "UV",  eu = 524288 }, { name = "UHV", eu = 2097152 },
    { name = "UEV", eu = 8388608 }, { name = "UIV", eu = 33554432 },
    { name = "UMV", eu = 134217728 }, { name = "UXV", eu = 536870912 },
    { name = "MAX", eu = 2147483640 },
}

constants.RATE_REFLUX_LEVELS = { [1] = true, [2] = true, [6] = true }
constants.T7_BOOST_OPTIONS = { 1, 1.25, 1.5, 1.75, 2 }
constants.PRODUCE_MISSING_SCANS = 3

constants.STOCK_PER_PARALLEL = 1000
constants.OPEN_RESERVE_MULTIPLIER = 5

constants.POWER_LEVELS = {
    [1] = 30720,
    [2] = 30720,
    [3] = 122880,
    [4] = 122880,
    [5] = 491520,
    [6] = 491520,
    [7] = 1966080,
    [8] = 7864320,
}

constants.RATE_PRODUCE = 900
constants.RATE_CONSUME = 1000
constants.RATE_REFLUX = 90
constants.RATE_REFLUX_BONUS = 0.15
constants.RATE_SUCCESS = { 0.7, 0.8, 1, 1, 0.99, 0.8, 1, 1 }
constants.RATE_SUCCESS_DUAL_LITHIUM = 0.9
constants.PARALLEL_CAP_T1 = 2386092
constants.PARALLEL_CAP_OTHER = 2147483

function constants.parallelCap(level)
    return level == 1 and constants.PARALLEL_CAP_T1 or constants.PARALLEL_CAP_OTHER
end

constants.LEVEL_NAMES = {
    [0] = "主机",
    [1] = "T1澄清",
    [2] = "T2臭氧",
    [3] = "T3絮凝",
    [4] = "T4调pH",
    [5] = "T5等离子",
    [6] = "T6紫外",
    [7] = "T7脱气",
    [8] = "T8萃取",
}

function constants.levelLabel(level)
    return constants.LEVEL_NAMES[level] or ("T" .. tostring(level))
end

function constants.levelCode(level)
    return "T" .. tostring(tonumber(level) or 0)
end

return constants
