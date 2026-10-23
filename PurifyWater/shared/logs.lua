--------------------------------------------------------------------------------
-- shared/logs.lua
--------------------------------------------------------------------------------
-- 【职责】日志缓冲：前缀种类、环形保留、待落盘队列、指纹
-- 【不做什么】不写盘（store/log_file 收）、不格式化
-- 【依赖】shared/config
-- 【被谁用】core/*、backend/*、frontend/panels/log、store/log_file
--
-- 发布线只保留用户可见日志；调试注入在 debugTools 分支。
-- 前缀即种类：[警告][调度][系统][界面]，无前缀 = info；界面按前缀上色。
--------------------------------------------------------------------------------

local CONFIG       = require("shared.config")

local logs         = {}

local lines        = {} -- 最近 MAX_LINES 行
local pending      = {} -- 待落盘行（T5 收走）
local maxLines     = (CONFIG.LOG and CONFIG.LOG.MAX_LINES) or 10
local maxPending   = (CONFIG.LOG and CONFIG.LOG.FILE_LINES) or 200
local pushed       = 0 -- 累计写入条数（指纹用）

--------------------------------------------------------------------------------
-- 种类（前缀 -> 种类 -> 颜色）
--------------------------------------------------------------------------------

-- 前缀表（顺序即匹配顺序；颜色在 theme.LOG_COLORS）
local KINDS = {
    { prefix = "[警告]", kind = "warn" },
    { prefix = "[调度]", kind = "schedule" },
    { prefix = "[系统]", kind = "system" },
    { prefix = "[界面]", kind = "ui" }
}

--- 一行日志的种类（按前缀判；没有前缀 = "info"）
-- @param text any
-- @return string "warn"|"schedule"|"system"|"ui"|"info"
function logs.kindOf(text)
    local s = tostring(text)
    for _, item in ipairs(KINDS) do
        if s:sub(1, #item.prefix) == item.prefix then return item.kind end
    end
    return "info"
end

--- 按种类写一行（前缀由这里统一加，调用方只给正文）
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

-- 快捷方式（前缀统一加）
function logs.warn(text) return note("warn", text) end

function logs.schedule(text) return note("schedule", text) end

function logs.system(text) return note("system", text) end

function logs.ui(text) return note("ui", text) end

--------------------------------------------------------------------------------
-- 写入
--------------------------------------------------------------------------------

--- 追加一行
-- @param text any
function logs.append(text)
    local line = tostring(text)
    lines[#lines + 1] = line
    while #lines > maxLines do table.remove(lines, 1) end

    pending[#pending + 1] = line
    pushed = pushed + 1
    while #pending > maxPending do table.remove(pending, 1) end
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

--- 当前缓冲的副本（调用方改它不影响缓冲）
-- @return table
function logs.list()
    local out = {}
    for i, line in ipairs(lines) do out[i] = line end
    return out
end

--- 指纹：条数/累计写入数/末行拼成单串。
-- @return string
function logs.fingerprint()
    return table.concat({ #lines, pushed, (lines[#lines] or "") }, "\x1f")
end

return logs
