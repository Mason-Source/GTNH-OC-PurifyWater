--------------------------------------------------------------------------------
-- PurifyWater/shared/config.lua
--
-- 定位：跨模块共享的静态可调参数表。
-- 功能：集中声明循环、采样、前端、速率、能源、网络、等级和日志的默认参数。
-- 边界：只保存部署期常量；运行期状态、用户设置和观测事实不得写入这里。
--------------------------------------------------------------------------------

-- 所有时间单位为秒；这些值只在部署时调整，运行期设置见 services/state.lua。
local CONFIG = {
    -- 无待办工作时的空闲等待范围。
    LOOP_MIN_IDLE = 0.05,
    LOOP_MAX_IDLE = 1.0,

    -- 硬件与周期观测间隔。
    INTERVAL = {
        HARDWARE = 10,
        HOST_PROGRESS = 3,
        WATER = 5,
    },

    -- 制作自动化扫描、单次转运比例和周期末截止比例。
    PRODUCE = {
        SCAN = 10,
        CHUNK_RATIO = 0.05,
        CYCLE_CUTOFF = 0.9,
    },
    -- 水位历史采样、环容量、落盘间隔和窗口长度。
    HISTORY = {
        INTERVAL = 30,
        POINTS = 80,
        SAVE_INTERVAL = 1000,
        PATH = "data/history.dat",
        WINDOW_MINUTES = 40,
    },


    -- 前端默认分辨率、主题和退出提示行。
    UI = {
        DEFAULT_THEME = "dark",
        THEMES = { "dark", "light" },
        THEME_LABELS = { dark = "深色", light = "浅色" },
        RESOLUTION_WIDTH = 128,
        RESOLUTION_HEIGHT = 40,
        EXIT_LOG_ROW = 3,
    },

    -- 速率模式权重、并行确认周期和零权重余量。
    RATES = {
        DEFAULT_WEIGHT = 0,
        MAX_WEIGHT = 100,
        DEFAULT_T7_BOOST = 1,
        PARALLEL_CONFIRM_CYCLES = 3,
        ZERO_MARGIN = 0.05,
    },

    -- 能源仓可用功率折算因子的合法区间。
    ENERGY = {
        FACTOR_MIN = 1,
        FACTOR_MAX = 100,
        FACTOR_DEFAULT = 100,
    },

    -- 无线快照广播端口、分块大小、刷新周期和失联阈值。
    NET = {
        PORT = 4096,
        CHUNK = 4000,
        INTERVAL = 10,
        REFRESH = 2,
        STALE = 30,
        STRENGTH_MAX = 400,
        STRENGTH_DEFAULT = 20,
    },

    -- 等级默认阈值与默认启用状态。
    LEVELS = {
        DEFAULT_THRESHOLD = 0,
        DEFAULT_ENABLED = true,
    },

    -- 日志批量落盘、单卷行数、卷数和前端可视行数。
    LOG = {
        FLUSH_INTERVAL = 5,
        CHUNK_LINES = 20,
        FILE_LINES = 200,
        FILE_COUNT = 10,
        VIEW_LINES = 80,
        PENDING_LINES = 300,
    },
}

return CONFIG
