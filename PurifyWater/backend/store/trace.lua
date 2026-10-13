--------------------------------------------------------------------------------
-- backend/store/trace.lua
--------------------------------------------------------------------------------
-- 【职责】运行痕迹：启动/退出各写一行到 data/last_run.txt
-- 【不做什么】不做日志缓冲（shared/logs）
-- 【依赖】store/files、shared/{constants,config}
-- 【被谁用】main.lua、monitor.lua
--
-- 用途：确认跑的版本与退出原因。
--------------------------------------------------------------------------------

local files     = require("backend.store.files")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")

local trace     = {}
local tracePath = nil
local MAX_LINES = 60 -- 只留最近 N 行（文件不会无限长）

--- 时间戳（OC 里 os.date 是游戏内时间）
-- @return string
local function stamp()
    return os.date("%m-%d %H:%M:%S")
end

--- 设定痕迹文件位置（data/ 下）
-- @return string 实际路径
function trace.setPath(appDir)
    tracePath = files.path(CONFIG.FILES.TRACE)
    return tracePath
end

--- @return string|nil 当前痕迹文件路径
function trace.path()
    return tracePath
end

--- 追加一行（超长自动裁剪）
-- @param text string
-- @return boolean
function trace.line(text)
    if not tracePath then return false end
    local lines = files.readLines(tracePath)
    lines[#lines + 1] = "[" .. stamp() .. "] " .. tostring(text)
    while #lines > MAX_LINES do table.remove(lines, 1) end
    return files.writeLines(tracePath, lines)
end

--- 记启动
-- @param version string|nil 内核版本戳
-- @param note string|nil 附加说明
function trace.start(appDir, version, note)
    trace.setPath(appDir)
    trace.line("启动：内核 " .. tostring(version or constants.CODE_VERSION) .. (note and ("，" .. note) or ""))
end

--- 记退出（由入口调用）
-- @param reason string|nil
-- @param note string|nil 附加说明
function trace.stop(reason, note)
    trace.line("退出：" .. tostring(reason or "未说明") .. (note and ("；" .. note) or ""))
end

return trace
