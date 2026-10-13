--------------------------------------------------------------------------------
-- backend/store/log_file.lua
--------------------------------------------------------------------------------
-- 【职责】把待落盘队列写进 data/log.txt（环形保留 FILE_LINES 行）
-- 【不做什么】不做缓冲与分级（shared/logs）、不写痕迹（store/trace）
-- 【依赖】store/files、shared/{config,logs}
-- 【被谁用】backend/jobs（T5）、main.lua（退出收尾）
--
-- 攒到 T5 一拍写一次，避免每行读全文件+改名；崩溃最多丢半分钟，痕迹即时写。
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

    -- 超上限丢最老（新行在后）
    local limit = (CONFIG.LOG and CONFIG.LOG.FILE_LINES) or 200
    while #lines > limit do table.remove(lines, 1) end

    local ok, err = files.writeLines(path(), lines)
    if not ok then return false, "写日志失败：" .. tostring(err) end
    logs.markFlushed()
    return true, string.format("日志已落盘（+%d 行，共 %d 行）", #fresh, #lines)
end

return log_file
