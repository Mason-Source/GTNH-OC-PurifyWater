local CONFIG                     = {}
CONFIG.FILES                     = {
    SETTINGS = "data/settings.txt", 
    HARDWARE = "data/hardware.txt", 
    HISTORY  = "data/history.dat",  
    LOG      = "data/log.txt",      
    TRACE    = "data/last_run.txt"  
}
CONFIG.INTERVAL                  = {
    HARDWARE  = 10,
    SETTINGS  = 5,
    FLUID     = 5,
    OBSERVE   = 5,
    SCHEDULE  = 5,
    PERSIST   = 30,
    SAMPLE    = 1,
    BROADCAST = 1
}
CONFIG.UI                        = {
    MAX_THRESHOLD_KILO   = 100000000000000,
    VIEW_REFRESH_SECONDS = 0.25,
    RESOLUTION_WIDTH     = 128,
    RESOLUTION_HEIGHT    = 40
}
CONFIG.CHART                     = {
    POINTS               = 80,
    SECONDS_PER_GAME_DAY = 86400,
    ALL_WINDOW_DAYS      = 1,
    LEVEL_WINDOW_DAYS    = 2
}
CONFIG.NET                       = {
    ENABLED = false,
    PORT    = 4096,
    CHUNK   = 4000,
    REFRESH = 2
}
CONFIG.LOOP_MIN_IDLE             = 0.05
CONFIG.LOOP_MAX_IDLE             = 1.0
CONFIG.PARALLEL_CONFIRM_CYCLES   = 3
CONFIG.PARALLEL_FALLBACK_SAMPLES = 24
CONFIG.LEVELS_DEFAULT            = {
    threshold = 0,
    enabled   = true
}
CONFIG.RATES                     = {
    DEFAULT_WEIGHT   = 0,
    MAX_WEIGHT       = 100,
    DEFAULT_T7_BOOST = 1,
    ZERO_MARGIN      = 0.05
}
CONFIG.SYSTEM                    = {
    PRIORITY_DEFAULT        = "low", 
    START_ON_BOOT           = false,
}
CONFIG.LOG                       = {
    LEVEL      = "user", 
    MAX_LINES  = 10,
    FILE_LINES = 200
}
return CONFIG
