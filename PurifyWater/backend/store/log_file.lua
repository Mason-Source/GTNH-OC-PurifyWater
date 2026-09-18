--------------------------------------------------------------------------------
-- backend/store/log_file.lua
--------------------------------------------------------------------------------
-- 【职责】把内存日志的"待落盘队列"写进 `data/log.txt`（环形保留 `CONFIG.LOG.FILE_LINES` 行）
-- 【不做什么】不做缓冲与分级（那是 shared/logs）、不写运行痕迹（那是 store/trace）
-- 【依赖】backend/store/files、shared/{config,logs}
-- 【被谁用】backend/jobs（T5，30 秒一次）、main.lua（退出前收尾）
--
-- 【为什么不写一行就落一次盘】盘是游戏里最慢的东西（机械硬盘 + OC 沙箱）：
--   每行都写 = 每行一次"读全文件 + 改名"；攒到 T5 一个节拍里 = 半分钟最多一次。
-- 【为什么内存里只留几行】日志的价值在"事后能翻"，不在"一直待在内存里"：
--   内存只留 `CONFIG.LOG.MAX_LINES`（屏幕上放得下的量），旧账看这个文件。
-- 【崩溃会丢什么】最多丢最后半分钟（下一拍之前的行）；内存痕迹（store/trace）是即时写的，
--   所以崩溃现场看 `data/last_run.txt` 不会被这一拍拖累。
--------------------------------------------------------------------------------

local CONFIG   = require("shared.config")
local logs     = require("shared.logs")
local files    = require("backend.store.files")

local log_file = {}

local function path()
    return files.path(CONFIG.FILES.LOG)
end

--- 把待落盘队列追加进日志文件（没有新行就一次盘都不碰）
-- @return boolean ok
-- @return string 说明
function log_file.flush()
    local fresh = logs.pendingLines()
    if #fresh == 0 then return true, "无新日志" end

    local lines = files.readLines(path())
    for _, line in ipairs(fresh) do lines[#lines + 1] = line end

    -- 超上限就丢最老的（与内存缓冲同一套语义：新的在最后）
    local limit = (CONFIG.LOG and CONFIG.LOG.FILE_LINES) or 200
    while #lines > limit do table.remove(lines, 1) end

    local ok, err = files.writeLines(path(), lines)
    if not ok then return false, "写日志失败：" .. tostring(err) end
    logs.markFlushed()
    return true, string.format("日志已落盘（+%d 行，共 %d 行）", #fresh, #lines)
end

--- 日志文件实际路径（排查用）
-- @return string
function log_file.path()
    return path()
end

return log_file
