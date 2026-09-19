local CONFIG       = require("shared.config")
local logs         = {}
local LEVEL_ORDER  = { user = 1, debug = 2 }
local buffer       = {}
local pending      = {}
local maxLines     = (CONFIG.LOG and CONFIG.LOG.MAX_LINES) or 10
local maxPending   = (CONFIG.LOG and CONFIG.LOG.FILE_LINES) or 200
local currentLevel = (CONFIG.LOG and CONFIG.LOG.LEVEL) or "user"
local pushed       = 0
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
function logs.getLevel() return currentLevel end
function logs.isDebug() return currentLevel == "debug" end
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
local KINDS = {
    { prefix = "[警告]", kind = "warn" },
    { prefix = "[调度]", kind = "schedule" },
    { prefix = "[系统]", kind = "system" },
    { prefix = "[界面]", kind = "ui" },
    { prefix = "[调试]", kind = "debug" }
}
function logs.kindOf(text)
    local s = tostring(text)
    for _, item in ipairs(KINDS) do
        if s:sub(1, #item.prefix) == item.prefix then return item.kind end
    end
    return "info"
end
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
function logs.warn(text) return note("warn", text) end
function logs.schedule(text) return note("schedule", text) end
function logs.system(text) return note("system", text) end
function logs.ui(text) return note("ui", text) end
local function visible(level)
    local need = LEVEL_ORDER[level or "user"] or LEVEL_ORDER.user
    return need <= (LEVEL_ORDER[currentLevel] or LEVEL_ORDER.user)
end
function logs.append(text, level)
    if not visible(level) then return end
    local line = tostring(text)
    buffer[#buffer + 1] = line
    pending[#pending + 1] = line
    pushed = pushed + 1
    while #buffer > maxLines do table.remove(buffer, 1) end
    while #pending > maxPending do table.remove(pending, 1) end
end
function logs.debug(text)
    logs.append(text, "debug")
end
function logs.pendingLines()
    local out = {}
    for i, line in ipairs(pending) do out[i] = line end
    return out
end
function logs.markFlushed()
    pending = {}
end
function logs.list()
    local out = {}
    for i, line in ipairs(buffer) do out[i] = line end
    return out
end
function logs.fingerprint()
    return table.concat({ #buffer, pushed, (buffer[#buffer] or ""), currentLevel }, "\x1f")
end
return logs
