local files     = require("backend.store.files")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local trace     = {}
local tracePath = nil
local MAX_LINES = 60
local function stamp()
    return os.date("%m-%d %H:%M:%S")
end
function trace.setPath(appDir)
    tracePath = files.path(CONFIG.FILES.TRACE)
    return tracePath
end
function trace.path()
    return tracePath
end
function trace.line(text)
    if not tracePath then return false end
    local lines = files.readLines(tracePath)
    lines[#lines + 1] = "[" .. stamp() .. "] " .. tostring(text)
    while #lines > MAX_LINES do table.remove(lines, 1) end
    return files.writeLines(tracePath, lines)
end
function trace.start(appDir, version, note)
    trace.setPath(appDir)
    trace.line("启动：内核 " .. tostring(version or constants.CODE_VERSION) .. (note and ("，" .. note) or ""))
end
function trace.stop(reason, note)
    trace.line("退出：" .. tostring(reason or "未说明") .. (note and ("；" .. note) or ""))
end
return trace
