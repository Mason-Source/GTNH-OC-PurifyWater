--------------------------------------------------------------------------------
-- shared/logs.lua
--------------------------------------------------------------------------------
-- 【职责】日志缓冲：分级（user / debug）、**种类（前缀即种类）**、内存环形保留、待落盘队列、指纹
-- 【不做什么】不写文件（盘上那份由 store/log_file 在 T5 收走待落盘队列）、不做格式化
-- 【依赖】shared/config
-- 【被谁用】core/*、backend/*、frontend/panels/log、backend/store/log_file
--
-- 【两份】内存只留 `CONFIG.LOG.MAX_LINES` 行（屏幕上放得下的量）；每行同时进"待落盘队列"，
--   T5（30 秒）收走写进 `data/log.txt`（保留 `CONFIG.LOG.FILE_LINES` 行）——
--   内存不必缓存一大堆，要翻旧账看盘上那份。
-- 【分级规则】debug 行在 user 级下**直接丢弃**（不入缓冲），否则会把用户级行挤出面板
--
-- 【写法规范】只准用下面这 5 个前缀：
--   [警告] 异常 / 失败 / 要人来处理        （红）
--   [调度] 调度与判定结果                   （青）
--   [系统] 系统状态变化（启停/锁定/硬件/采样写入）（白）
--   [界面] 界面操作回执与拒绝原因           （灰）
--   [调试] debug 级细节                     （灰）
--   没前缀的行按 info（白）算；界面**只按前缀上色**，不再用 find("警告") 猜。
--   新代码推荐 `logs.warn/schedule/system/ui(...)`：前缀由 logs 统一加，不会拼错。
--------------------------------------------------------------------------------

local CONFIG       = require("shared.config")

local logs         = {}

local LEVEL_ORDER  = { user = 1, debug = 2 }
local buffer       = {} -- 面板读的那份：只留屏幕上放得下的行数
local pending      = {} -- 已生成、还没写进 data/log.txt 的行（T5 收走）
local maxLines     = (CONFIG.LOG and CONFIG.LOG.MAX_LINES) or 10
local maxPending   = (CONFIG.LOG and CONFIG.LOG.FILE_LINES) or 200
local currentLevel = (CONFIG.LOG and CONFIG.LOG.LEVEL) or "user"
local pushed       = 0 -- 累计写入条数（指纹用：裁剪后条数不变也能看出有新行）

--------------------------------------------------------------------------------
-- 级别
--------------------------------------------------------------------------------

--- 设置级别（非法级别返回 false，不改变现状）
-- 切换级别时清空缓冲：两个级别的行混在一屏里分不清归属。清完补一行说明，
-- 免得屏幕突然空掉像出了故障（该行在切换之后写，必然符合新级别）。
-- @param level string "user" | "debug"
-- @return boolean
function logs.setLevel(level)
    if LEVEL_ORDER[level] == nil then return false end
    local changed = (level ~= currentLevel)
    currentLevel = level
    if CONFIG.LOG then CONFIG.LOG.LEVEL = level end
    if changed then
        buffer = {}
        logs.system("日志级别 = " .. level)
    end
    return true
end

--- @return string 当前级别
function logs.getLevel() return currentLevel end

--- @return boolean 是否 debug 级
function logs.isDebug() return currentLevel == "debug" end

--- 解析命令行参数里的日志级别（--debug / -d / --log-level=debug）
-- @param args table 命令行参数数组
-- @return boolean 是否开启了 debug
function logs.applyArgs(args)
    local wantDebug = false
    for _, raw in ipairs(args or {}) do
        local s = tostring(raw)
        if s == "--debug" or s == "-d" or s == "--verbose" then wantDebug = true end
        if s == "--log=debug" or s == "--log-level=debug" then wantDebug = true end
        if s == "--log=user" or s == "--log-level=user" then wantDebug = false end
    end
    logs.setLevel(wantDebug and "debug" or "user")
    return wantDebug
end

--------------------------------------------------------------------------------
-- 种类（前缀 -> 种类 -> 颜色）
--------------------------------------------------------------------------------

-- 前缀表（**顺序就是匹配顺序**；界面靠它判种类，颜色在 theme.LOG_COLORS）
local KINDS = {
    { prefix = "[警告]", kind = "warn" },
    { prefix = "[调度]", kind = "schedule" },
    { prefix = "[系统]", kind = "system" },
    { prefix = "[界面]", kind = "ui" },
    { prefix = "[调试]", kind = "debug" }
}

--- 一行日志的种类（按**前缀**判；没有前缀 = "info"）
-- @param text any
-- @return string "warn"|"schedule"|"system"|"ui"|"debug"|"info"
function logs.kindOf(text)
    local s = tostring(text)
    for _, item in ipairs(KINDS) do
        if s:sub(1, #item.prefix) == item.prefix then return item.kind end
    end
    return "info"
end

--- 按种类写一行（**前缀由这里统一加**，调用方只给正文）
-- @param kind string "warn"|"schedule"|"system"|"ui"
-- @param text any
local function note(kind, text)
    local prefix = "[" .. tostring(kind) .. "]"
    for _, item in ipairs(KINDS) do
        if item.kind == kind then
            prefix = item.prefix
            break
        end
    end
    logs.append(prefix .. " " .. tostring(text))
end

-- 快捷方式（新代码用这些；前缀由上面统一加，不会拼错）
function logs.warn(text) return note("warn", text) end

function logs.schedule(text) return note("schedule", text) end

function logs.system(text) return note("system", text) end

function logs.ui(text) return note("ui", text) end

--------------------------------------------------------------------------------
-- 写入
--------------------------------------------------------------------------------

--- 该级别在当前设置下是否可见
-- @param level string|nil
-- @return boolean
local function visible(level)
    local need = LEVEL_ORDER[level or "user"] or LEVEL_ORDER.user
    return need <= (LEVEL_ORDER[currentLevel] or LEVEL_ORDER.user)
end

--- 追加一行（默认 user 级）
-- 隐藏级别**不入缓冲**（不是"存起来但不显示"）。
-- 不写时间戳：OC 的 os.time 是**游戏内时间**（1 游戏日 = 86400 os 秒），与现实无关；行序即操作顺序。
-- @param text any
-- @param level string|nil "user" | "debug"
function logs.append(text, level)
    if not visible(level) then return end
    local line = tostring(text)
    buffer[#buffer + 1] = line
    pending[#pending + 1] = line
    pushed = pushed + 1
    while #buffer > maxLines do table.remove(buffer, 1) end
    -- 待落盘队列也夹住：盘上那份只保留 FILE_LINES 行，再多也是会被挤掉的
    --   （万一写盘一直失败，内存也不会因此无限涨 —— 那正是这轮要修的病）
    while #pending > maxPending do table.remove(pending, 1) end
end

--- 追加一行 debug 级（默认不显示，`--debug` 才入缓冲）
-- @param text any
function logs.debug(text)
    logs.append(text, "debug")
end

--------------------------------------------------------------------------------
-- 待落盘（盘上那份日志由 store/log_file 收）
--------------------------------------------------------------------------------

--- 取走"还没落盘"的行（副本：调用方写盘成功后调 `logs.markFlushed`）
-- @return table 行数组
function logs.pendingLines()
    local out = {}
    for i, line in ipairs(pending) do out[i] = line end
    return out
end

--- 待落盘队列已进盘（`store/log_file` 写成功后调用）
function logs.markFlushed()
    pending = {}
end

--------------------------------------------------------------------------------
-- 读取
--------------------------------------------------------------------------------

--- 取副本（调用方改它不会影响缓冲）
-- @return table
function logs.list()
    local out = {}
    for i, line in ipairs(buffer) do out[i] = line end
    return out
end

--- 指纹：条数 / 累计写入数 / 末行 / 级别（**拼成一个串**）
-- 四个成分各有用途：条数被裁剪后不再变化，累计写入数才反映"有新行"；末行相同但级别变了也要重绘。
-- 拼成一个串返回：多返回值只在**最后一个**表达式才展开，分开返回会被调用方丢掉后几个。
-- @return string
function logs.fingerprint()
    return table.concat({ #buffer, pushed, (buffer[#buffer] or ""), currentLevel }, "\x1f")
end

return logs
