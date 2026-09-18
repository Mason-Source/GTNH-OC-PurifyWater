local CONFIG                     = {}
CONFIG.FILES                     = {
    RECORDS  = "data/records.txt",  
    LEVELS   = "data/levels.txt",   
    HARDWARE = "data/hardware.txt", 
    HISTORY  = "data/history.dat",  
    LOG      = "data/log.txt",      
    SETTINGS = "data/settings.txt", 
    TRACE    = "data/last_run.txt"  
}
CONFIG.INTERVAL                  = {
    HARDWARE  = 10,
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
CONFIG.SYSTEM                    = {
    PRIORITY_DEFAULT        = "low", 
    START_ON_BOOT           = false,
    RELEARN_ON_POWER_CHANGE = true,
    RELEARN_ON_UNIT_CHANGE  = true
}
CONFIG.LOG                       = {
    LEVEL      = "user", 
    MAX_LINES  = 10,
    FILE_LINES = 200
}
return CONFIG
