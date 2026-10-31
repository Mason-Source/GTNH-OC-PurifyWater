-- 可调参数；不含运行期数据。
local CONFIG = {
    LOOP_MIN_IDLE = 0.05,
    LOOP_MAX_IDLE = 1.0,

    INTERVAL = {
        HARDWARE = 10,
        HOST_PROGRESS = 3,
        WATER = 5,
    },

    PRODUCE = {
        SCAN = 10,
        CHUNK_RATIO = 0.05,
        CYCLE_CUTOFF = 0.9,
    },
    HISTORY = {
        INTERVAL = 30,
        POINTS = 80,
        SAVE_INTERVAL = 1000,
        PATH = "data/history.dat",
        WINDOW_MINUTES = 40,
    },


    UI = {
        DEFAULT_THEME = "dark",
        THEMES = { "dark", "light" },
        THEME_LABELS = { dark = "深色", light = "浅色" },
        RESOLUTION_WIDTH = 128,
        RESOLUTION_HEIGHT = 40,
        EXIT_LOG_ROW = 3,
    },

    RATES = {
        DEFAULT_WEIGHT = 0,
        MAX_WEIGHT = 100,
        DEFAULT_T7_BOOST = 1,
        PARALLEL_CONFIRM_CYCLES = 3,
        ZERO_MARGIN = 0.05,
    },

    ENERGY = {
        FACTOR_MIN = 1,
        FACTOR_MAX = 100,
        FACTOR_DEFAULT = 100,
    },

    NET = {
        PORT = 4096,
        CHUNK = 4000,
        INTERVAL = 10,
        REFRESH = 2,
        STALE = 30,
        STRENGTH_MAX = 400,
        STRENGTH_DEFAULT = 20,
    },

    LEVELS = {
        DEFAULT_THRESHOLD = 0,
        DEFAULT_ENABLED = true,
    },

    LOG = {
        FLUSH_INTERVAL = 5,
        CHUNK_LINES = 20,
        FILE_LINES = 200,
        FILE_COUNT = 10,
        VIEW_LINES = 80,
    },
}

return CONFIG
