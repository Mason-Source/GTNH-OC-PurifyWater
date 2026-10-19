--------------------------------------------------------------------------------
-- shared/config.lua
--------------------------------------------------------------------------------
-- 【职责】全部可调参数：周期、文件名、循环节奏、镜像端口、默认阈值
-- 【不做什么】不含常量（shared/constants）、不含运行期数据（shared/state）
-- 【依赖】无
-- 【被谁用】core/*、backend/*、frontend/*
--------------------------------------------------------------------------------

local CONFIG                     = {}

-- ---- 数据文件 ----
-- 数据集中在 data/。settings.txt 键=值可手改，重启后生效；其余改坏重建。
CONFIG.FILES                     = {
    SETTINGS = "data/settings.txt", -- **全部可配置项**（阈值/勾选/运行模式…；键=值，用户可手改）
    HARDWARE = "data/hardware.txt", -- 硬件拓扑清单（有变化才写）
    HISTORY  = "data/history.dat",  -- 曲线点（一行一点）
    LOG      = "data/log.txt",      -- 日志（T5 每 30 秒把内存里的新行追加进来）
    TRACE    = "data/last_run.txt", -- 启动/退出痕迹 + 内存紧张时的留痕
    PRODUCE  = "data/produce.txt"   -- 制作自动化绑定表（绑定程序写入；一行一台机器）
}

-- ---- 定时任务周期（秒） ----
CONFIG.INTERVAL                  = {
    HARDWARE  = 10, -- T1 重扫机器（能源仓/ME接口/水厂）
    FLUID     = 5,  -- T2 读 1-8 级水缓存
    OBSERVE   = 5,  -- T3 读开关/运行；在运行的读传感器
    SCHEDULE  = 5,  -- T4 贪心调度
    PERSIST   = 30, -- T5 落盘（抽曲线点 + 写历史/日志）
    SAMPLE    = 1,  -- T6 内存采样（仅 --debug 注册）
    BROADCAST = 1,  -- T7 无线广播（门控：总开关 + 网卡在位）
    PRODUCE   = 1,  -- T8 制作自动化（绑定检测 + T0 周期钟；只有"绑定中"才枚举转运器）
    PRODUCE_RUNTIME = 0.5 -- 制作自动化 operation runtime（空队列时只扫一个小表）
}

-- ---- 界面（可调） ----
CONFIG.UI                        = {
    -- 配置页阈值上限（kL，≥1e14 拒收）；
    MAX_THRESHOLD_KILO   = 100000000000000,
    -- 视图重建间隔（秒）；面板指纹挡着，没变不画
    VIEW_REFRESH_SECONDS = 0.25,

    -- 分辨率；0 = 不改。启动设置、退出还原。
    RESOLUTION_WIDTH     = 128,
    RESOLUTION_HEIGHT    = 40
}

-- ---- 曲线 ----
-- 时间单位 = os.time 秒（游戏内时间）；1 游戏日 = 86400。
-- POINTS 是内存与盘的上限，须盖住最长窗口（单级 2 游戏日 = 80 点）。
CONFIG.CHART                     = {
    POINTS               = 80,    -- 原始点数（= 单级窗口）
    SECONDS_PER_GAME_DAY = 86400, -- 1 游戏日跨度（唯一换算处）
    ALL_WINDOW_DAYS      = 1,     -- 全部柱状图窗口
    LEVEL_WINDOW_DAYS    = 2      -- 单级曲线窗口
}

-- ---- 无线广播（镜像端） ----
CONFIG.NET                       = {
    -- 开关与范围都存 settings.txt（程序重启保持）；ENABLED/STRENGTH 只是缺键时的默认值
    ENABLED        = false,               -- 广播总开关默认值（关着时 T7 完全不动作）
    ENABLED_KEY    = "net_enabled",       -- settings.txt 的键
    PORT           = 4096,                -- 无线端口
    CHUNK          = 4000,                -- 分片字节数（OC 单条消息上限 8192）
    REFRESH        = 2,                   -- 镜像端状态刷新间隔（秒）
    STRENGTH       = 20,                  -- 无线范围默认值（方块）
    STRENGTH_KEY   = "net_strength",      -- settings.txt 的键
    STRENGTH_MAX   = 400                  -- 兜底上限（= OpenComputers.cfg maxWirelessRange[2]；下发时卡还会再夹一次）
}

-- ---- 主循环 ----
-- event.pull 的超时 = clamp(最近到期任务, MIN, MAX)
CONFIG.LOOP_MIN_IDLE             = 0.05
CONFIG.LOOP_MAX_IDLE             = 1.0

-- OC 无 collectgarbage；内存控制靠少造垃圾、少留数据。

-- ---- 并行确认（domain/tracker） ----
-- 并行在配方周期内恒定、周期之间变：连续 N 个周期同值才稳定。
-- 周期边界 = getWorkProgress 回落。
CONFIG.PARALLEL_CONFIRM_CYCLES   = 3

-- ---- 阈值文件默认值 ----
-- 文件缺失/损坏时按此生成。
-- 阈值 0 = 不使用用户阈值；保供线仍生效。
CONFIG.LEVELS_DEFAULT            = {
    threshold = 0,   -- 默认阈值 0（= 不因阈值开启）
    enabled   = true -- 默认全部勾选（勾选 = 该级受阈值管理）
}

-- ---- 速率模式（权重调度） ----
-- 模型常数在 shared/constants；这里只有可调默认值。
CONFIG.RATES                     = {
    DEFAULT_WEIGHT   = 0,   -- 新装权重全 0（到配置页填写）
    MAX_WEIGHT       = 100, -- 权重上限（界面/命令同一判据）
    DEFAULT_T7_BOOST = 1,   -- T7 增产倍率默认档
    DEFAULT_T6_DUAL_LITHIUM = false, -- T6 是否使用双锂数据收集
    -- w=0 纯过路级的库存余量（垫住取整亏欠）
    ZERO_MARGIN      = 0.05
}

-- ---- 制作自动化 ----
CONFIG.PRODUCE                   = {
    CHUNK_RATIO  = 0.05, -- 单笔上限 = floor(rate*0.05)；≤ 此值保证 transferFluid 永不触发 context.pause
    CYCLE_CUTOFF = 0.9,  -- 周期尾段保护：周期进度超过 90% 时不再开始新机器
}


-- ---- 能源仓利用因子（可用功率 = 折算最大功率 × 因子%） ----
CONFIG.ENERGY                    = {
    FACTOR_KEY     = "energy_factor", -- settings.txt 的键
    FACTOR_MIN     = 1,               -- %
    FACTOR_MAX     = 100,             -- %
    FACTOR_DEFAULT = 100              -- 缺键/非法值回退
}

-- ---- 系统行为 ----
CONFIG.SYSTEM                    = {
    -- 运行模式为永久配置（存 settings.txt）；默认值仅首次生效。
    PRIORITY_DEFAULT        = "low", -- "low" = 低级水优先 / "high" = 高级水优先
    START_ON_BOOT           = false, -- 启动即自动开调度

    -- 安全状态只保留只读逻辑；手动点【启动系统】恢复。
}

-- ---- 日志 ----
CONFIG.LOG                       = {
    LEVEL      = "user", -- user | debug（--debug 打开）
    -- 内存只留 MAX_LINES 行；超出删最前。
    MAX_LINES  = 10,
    -- 盘上 data/log.txt 保留行数（T5 追加并裁到上限）。
    FILE_LINES = 200
}

return CONFIG
