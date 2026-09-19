local constants                   = {}
constants.CODE_VERSION            = "v4.1"
constants.LEVEL_COUNT             = 8
constants.HOST_LEVEL              = 0
constants.STOCK_PER_PARALLEL      = 1000
constants.OPEN_RESERVE_MULTIPLIER = 5
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
constants.KEY_CODES               = {
    Q = 16,
    R = 19,
    X = 45
}
function constants.levelLabel(level)
    return constants.LEVEL_NAMES[level] or ("T" .. tostring(level))
end
return constants
