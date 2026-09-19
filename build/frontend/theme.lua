local theme      = {}
theme.COLORS     = {
    BG                = 0x0d1117,
    BORDER            = 0x1e3a8a,
    BORDER_ALERT      = 0x991b1b,
    TEXT              = 0xe2e8f0,
    TEXT_CYAN         = 0x38bdf8,
    TEXT_GREEN        = 0x22c55e,
    TEXT_YELLOW       = 0xf59e0b,
    TEXT_RED          = 0xef4444,
    TEXT_DISABLED     = 0x64748b,
    BTN_BG            = 0x1e293b,
    BTN_BG_HOVER      = 0x334155,
    BTN_BG_DISABLED   = 0x111827,
    BTN_PRIORITY_HIGH = 0x7f1d1d,
    BAR_BG            = 0x86efac,
    BAR_FILL          = 0x22c55e,
    BAR_BG_EMPTY      = 0x450a0a,
    CYCLE_BG          = 0x1e293b,
    CYCLE_FILL        = 0x38bdf8
}
theme.LOG_COLORS = {
    warn     = 0xef4444,
    schedule = 0x38bdf8,
    system   = 0xe2e8f0,
    ui       = 0x64748b,
    debug    = 0x64748b,
    info     = 0xe2e8f0
}
function theme.logColor(kind)
    return theme.LOG_COLORS[kind] or theme.COLORS.TEXT
end
theme.CHART_GRID  = 0x2a3a5a
theme.CHART_AXIS  = 0x64748b
theme.CHART_WATER = 0x0ea5e9
theme.SERIES      = {
    0x38bdf8,
    0x22c55e,
    0xf59e0b,
    0xa855f7,
    0xef4444,
    0x14b8a6,
    0xeab308,
    0xf472b6
}
function theme.seriesColor(level)
    return theme.SERIES[level] or theme.CHART_WATER
end
function theme.borderColor(highFirst)
    return highFirst and theme.COLORS.BORDER_ALERT or theme.COLORS.BORDER
end
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
