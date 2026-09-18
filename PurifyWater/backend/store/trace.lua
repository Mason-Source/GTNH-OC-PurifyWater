--------------------------------------------------------------------------------
-- backend/store/trace.lua
--------------------------------------------------------------------------------
-- 【职责】运行痕迹：启动 / 退出 各写一行，写在 **data/last_run.txt**（统一数据目录）
-- 【不做什么】不做日志缓冲（那是 shared/logs，纯内存）
-- 【依赖】store/files、shared/{constants,config}
-- 【被谁用】main.lua / monitor.lua
--
-- 放应用目录下的 data/：应用目录一定可写，文件系统根目录则要看机器。
-- 留痕的用途：确认"跑的是哪一份"、看退出原因 —— 屏幕上的字抄不出来。
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

--- 设定痕迹文件位置（**统一在 data/ 下**，路径由 CONFIG.FILES.TRACE 决定）
-- @param appDir string 应用根目录（实际位置由 files.setRoot 决定，参数保留兼容调用方）
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

--- 记启动（由入口调用）
-- @param appDir string
-- @param version string|nil 内核版本戳（入口传 `bootstrap.version()` —— 带 -debug 后缀；缺省用常量原值）
-- @param note string|nil 附加说明（例如"硬件齐全"）
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
