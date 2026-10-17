--------------------------------------------------------------------------------
-- shared/logs.lua
--------------------------------------------------------------------------------
-- 【职责】日志缓冲：分级、前缀种类、环形保留、待落盘队列、指纹
-- 【不做什么】不写盘（store/log_file 收）、不格式化
-- 【依赖】shared/config
-- 【被谁用】core/*、backend/*、frontend/panels/log、store/log_file
--
-- user/debug 各自留 MAX_LINES 行；切换级别只换显示哪一级；
-- 当前是 debug 时，user 行也进 debug 缓冲 —— 面板上屏要能同时看到警告/系统行与调试明细。
-- 当前级别可见的行同时进待落盘队列，T5 写 data/log.txt（保留 FILE_LINES 行）。
-- 前缀即种类：[警告][调度][系统][界面][调试]，无前缀 = info；界面按前缀上色。
-- 新代码用 logs.warn/schedule/system/ui/debug()，前缀由本模块统一加。
--------------------------------------------------------------------------------

local CONFIG       = require("shared.config")

local logs         = {}

local LEVEL_ORDER  = { user = 1, debug = 2 }
local buffers      = { user = {}, debug = {} } -- 两级各留各的最后几行
local pending      = {} -- 待落盘行（T5 收走）
local maxLines     = (CONFIG.LOG and CONFIG.LOG.MAX_LINES) or 10
local maxPending   = (CONFIG.LOG and CONFIG.LOG.FILE_LINES) or 200
local currentLevel = (CONFIG.LOG and CONFIG.LOG.LEVEL) or "user"
local pushed       = 0 -- 可见级别累计写入条数（指纹用）

--------------------------------------------------------------------------------
-- 级别
--------------------------------------------------------------------------------

--- 设置级别（非法返回 false）
-- 切换只换当前显示哪一级，不清空各级缓冲。
-- @param level string "user" | "debug"
-- @return boolean
function logs.setLevel(level)
    if LEVEL_ORDER[level] == nil then return false end
    local changed = (level ~= currentLevel)
    currentLevel = level
    if CONFIG.LOG then CONFIG.LOG.LEVEL = level end
    if changed then
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

-- 前缀表（顺序即匹配顺序；颜色在 theme.LOG_COLORS）
local KINDS = {
    { prefix = "[警告]", kind = "warn" },
    { prefix = "[调度]", kind = "schedule" },
    { prefix = "[系统]", kind = "system" },
    { prefix = "[界面]", kind = "ui" },
    { prefix = "[调试]", kind = "debug" }
}

--- 一行日志的种类（按前缀判；没有前缀 = "info"）
-- @param text any
-- @return string "warn"|"schedule"|"system"|"ui"|"debug"|"info"
function logs.kindOf(text)
    local s = tostring(text)
    for _, item in ipairs(KINDS) do
        if s:sub(1, #item.prefix) == item.prefix then return item.kind end
    end
    return "info"
end

--- 按种类写一行（前缀由这里统一加，调用方只给正文）
-- @param kind string "warn"|"schedule"|"system"|"ui"|"debug"
-- @param text any
-- @param level string|nil 该行级别；默认 user
local function note(kind, text, level)
    local prefix = "[" .. tostring(kind) .. "]"
    for _, item in ipairs(KINDS) do
        if item.kind == kind then
            prefix = item.prefix
            break
        end
    end
    logs.append(prefix .. " " .. tostring(text), level)
end

-- 快捷方式（前缀统一加）
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
-- 各级缓冲各自保留；可见才进待落盘队列。不写时间戳：os.time 是游戏内时间，行序即操作顺序。
-- @param text any
-- @param level string|nil "user" | "debug"
function logs.append(text, level)
    local lv   = level or "user"
    local line = tostring(text)
    local buf  = buffers[lv]
    if buf then
        buf[#buf + 1] = line
        while #buf > maxLines do table.remove(buf, 1) end
    end
    -- 【上屏】低级别的行也进"当前级别"的缓冲：否则 --debug 时面板只画 [调试] 行，
    --   警告 / 系统行只落盘不上屏（面板按到达顺序混排）。
    local cur = buffers[currentLevel]
    if cur and cur ~= buf and visible(lv) then
        cur[#cur + 1] = line
        while #cur > maxLines do table.remove(cur, 1) end
    end
    if not visible(level) then return end
    pending[#pending + 1] = line
    pushed = pushed + 1
    -- 队列夹住：写盘一直失败也不无限涨
    while #pending > maxPending do table.remove(pending, 1) end
end

--- 追加一行 debug 级（user 级不显示，但保留在 debug 缓冲里）
-- @param text any
function logs.debug(text)
    return note("debug", text, "debug")
end

--------------------------------------------------------------------------------
-- 待落盘（盘上那份日志由 store/log_file 收）
--------------------------------------------------------------------------------

--- 取待落盘行的副本（写盘成功后调 markFlushed）
-- @return table 行数组
function logs.pendingLines()
    local out = {}
    for i, line in ipairs(pending) do out[i] = line end
    return out
end

--- 待落盘队列已进盘（store/log_file 写成功后调用）
function logs.markFlushed()
    pending = {}
end

--------------------------------------------------------------------------------
-- 读取
--------------------------------------------------------------------------------

--- 当前级别缓冲的副本（调用方改它不影响缓冲）
-- @return table
function logs.list()
    local buf = buffers[currentLevel] or {}
    local out = {}
    for i, line in ipairs(buf) do out[i] = line end
    return out
end

--- 指纹：当前级别条数/可见累计写入数/末行/级别，拼成单串。
-- 单串返回：多返回值只有最后一个表达式会展开，分开会被调用方丢。
-- @return string
function logs.fingerprint()
    local buf = buffers[currentLevel] or {}
    return table.concat({ #buf, pushed, (buf[#buf] or ""), currentLevel }, "")
end

return logs
