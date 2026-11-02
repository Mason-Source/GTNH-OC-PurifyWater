--------------------------------------------------------------------------------
-- PurifyWater/services/log.lua
--
-- 定位：内存日志队列与轮转写盘核心。
-- 功能：提供四级日志、最近记录视图、固定行块落盘和最多十卷的日志轮转。
-- 边界：业务只入队；文件写入由 log.flush 执行，单条日志不直接写磁盘。
--------------------------------------------------------------------------------

local config = require("shared.config")
local clock = require("services.clock")
local storage = require("services.storage")

local log = {}
local CHUNK = config.LOG.CHUNK_LINES or 20
local MAX_PENDING = config.LOG.PENDING_LINES or 300
local FILE_LINES = config.LOG.FILE_LINES
local FILE_COUNT = config.LOG.FILE_COUNT
local VIEW_LINES = config.LOG.VIEW_LINES or 80
local pending = {}
local recent = {}
local seq = 0
local lastLine = nil
local activePath = nil
local activeLines = 0

local KIND = {
    ERROR = "error",
    WARN = "warn",
    SYSTEM = "system",
    DIAG = "diag",
}

local function newPath()
    return "log/log-" .. os.date("%Y%m%d-%H%M%S", clock.realTime()) .. ".txt"
end

local function logFiles()
    local files = storage.list("log/log-")
    table.sort(files)
    return files
end

local function startFile()
    local files = logFiles()
    if #files >= FILE_COUNT and not storage.remove(files[1]) then
        return false, "cannot remove oldest log"
    end
    activePath = newPath()
    activeLines = 0
    return true
end

local function ensureFile()
    if activePath then return true end
    local files = logFiles()
    if #files > 0 then
        local latest = files[#files]
        local lines = #storage.readLines(latest)
        if lines < FILE_LINES then
            activePath = latest
            activeLines = lines
            return true
        end
    end
    return startFile()
end

local function appendPart(lines)
    local ok, err = storage.append(activePath, lines)
    if not ok then return false, err end
    activeLines = activeLines + #lines
    if activeLines == FILE_LINES then activePath = nil end
    return true
end

local function writeChunk(chunk)
    local ok, err = ensureFile()
    if not ok then return false, err end

    local room = FILE_LINES - activeLines
    if #chunk <= room then return appendPart(chunk) end

    local head = {}
    for index = 1, room do head[index] = chunk[index] end
    if room > 0 then
        ok, err = appendPart(head)
        if not ok then return false, err end
    end

    local rest = {}
    for index = room + 1, #chunk do rest[#rest + 1] = chunk[index] end
    ok, err = startFile()
    if not ok then return false, err end
    return appendPart(rest)
end

local function append(level, message)
    seq = seq + 1
    local record = {
        seq = seq,
        at = clock.realTime(),
        kind = KIND[level] or "system",
        level = level,
        text = tostring(message or ""),
    }
    recent[#recent + 1] = record
    if #recent > VIEW_LINES then table.remove(recent, 1) end
    lastLine = string.format("%.3f|%s|%s", clock.uptime(), level, record.text)
    pending[#pending + 1] = lastLine
    if #pending > MAX_PENDING then
        table.remove(pending, 1)
    end
end

--- 追加一条 ERROR 级内存日志。
function log.error(message) append("ERROR", message) end
--- 追加一条 WARN 级内存日志。
function log.warn(message) append("WARN", message) end
--- 追加一条 SYSTEM 级内存日志。
function log.system(message) append("SYSTEM", message) end
--- 追加一条仅供诊断、默认不在前端显示的 DIAG 日志。
function log.diag(message) append("DIAG", message) end

--- 返回累计生成的日志条数。
function log.count() return seq end
--- 返回日志内容版本号。
function log.revision() return seq end
--- 返回最近一条日志的落盘文本行。
function log.last() return lastLine end
--- 返回尚未写入磁盘的日志条数。
function log.pendingCount() return #pending end

--- 返回最近日志记录的结构化副本。
function log.entries()
    local out = {}
    for index = 1, #recent do
        local item = recent[index]
        out[index] = {
            seq = item.seq,
            at = item.at,
            kind = item.kind,
            level = item.level,
            text = item.text,
        }
    end
    return out
end

--- 把待写队列按固定行块写入并轮转日志文件。
function log.flush()
    if #pending == 0 then return true, activePath or "-" end
    local consumed = 0
    while consumed < #pending do
        local count = math.min(CHUNK, #pending - consumed)
        local chunk = {}
        for index = 1, count do chunk[index] = pending[consumed + index] end
        local ok, err = writeChunk(chunk)
        if not ok then
            if consumed > 0 then
                local rest = {}
                for index = consumed + 1, #pending do rest[#rest + 1] = pending[index] end
                pending = rest
            end
            return false, err
        end
        consumed = consumed + count
    end
    pending = {}
    return true, activePath or "-"
end

return log