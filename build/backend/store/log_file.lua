local CONFIG   = require("shared.config")
local logs     = require("shared.logs")
local files    = require("backend.store.files")
local log_file = {}
local function path()
    return files.path(CONFIG.FILES.LOG)
end
function log_file.flush()
    local fresh = logs.pendingLines()
    if #fresh == 0 then return true, "无新日志" end
    local lines = files.readLines(path())
    for _, line in ipairs(fresh) do lines[#lines + 1] = line end
    local limit = (CONFIG.LOG and CONFIG.LOG.FILE_LINES) or 200
    while #lines > limit do table.remove(lines, 1) end
    local ok, err = files.writeLines(path(), lines)
    if not ok then return false, "写日志失败：" .. tostring(err) end
    logs.markFlushed()
    return true, string.format("日志已落盘（+%d 行，共 %d 行）", #fresh, #lines)
end
function log_file.path()
    return path()
end
return log_file
