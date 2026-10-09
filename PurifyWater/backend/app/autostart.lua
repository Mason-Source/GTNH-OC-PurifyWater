--------------------------------------------------------------------------------
-- backend/app/autostart.lua
--------------------------------------------------------------------------------
-- 【职责】开机自启的**用例**：启动时读一次、勾选/取消、写用户看得见的日志
-- 【不做什么】不碰文件字节（backend/store/autostart）、不画界面（frontend/panels/settings）
-- 【依赖】backend/store/autostart、shared/{state,logs}
-- 【被谁用】main.lua（启动 refresh）、backend/api.lua（COMMANDS.autostart_toggle）
--
-- 【真源 = .shrc 里的标记块】不另存 data/settings.txt：手改 .shrc 后重启程序即所见即所得；
--   块在但指向别的路径只标记 stale + 警告，不自动改用户的文件（程序不替用户做决定）。
-- 【生效时机】写盘只影响**下次开机**（或下次新建 shell）；本次运行不受影响。
--------------------------------------------------------------------------------

local logs      = require("shared.logs")
local state     = require("shared.state")

local store     = require("backend.store.autostart")

local autostart = {}

--- 从盘上读一次，同步到 state、按需写日志（启动与勾选后各调一次）
-- @return boolean enabled
function autostart.refresh()
    local info = store.read()

    state.system.autostart      = info.enabled == true
    state.system.autostartStale = info.stale == true
    state.system.autostartPath  = info.path

    if info.enabled then
        logs.system(string.format("开机自启：已开启（%s）", tostring(info.path)))
    elseif info.stale then
        logs.warn(string.format("开机自启指向其它路径：%s（配置页勾选可更新为当前程序）",
            tostring(info.target or "?")))
    end
    if info.manualLine then
        logs.warn("检测到 .shrc 里还有一行手动启动本程序，开机可能重复启动：" .. tostring(info.manualLine))
    end
    return state.system.autostart
end

--- 勾选 / 取消（配置页「运行设置」那一行）；成功与否都自己写日志，界面不重复回执
-- @return boolean ok
-- @return string 说明（失败原因；成功时为空）
function autostart.toggle()
    if not state.system.autostart then
        local ok, info = store.enable()
        if not ok then
            local text = "开机自启开启失败：" .. tostring(info)
            logs.warn(text)
            return false, text
        end
        state.system.autostart, state.system.autostartStale = true, false
        state.system.autostartPath = info
        logs.system(string.format("开机自启已开启：%s（下次开机生效）", tostring(info)))
        return true, ""
    end

    local ok, info = store.disable()
    if not ok then
        local text = "开机自启取消失败：" .. tostring(info)
        logs.warn(text)
        return false, text
    end
    state.system.autostart, state.system.autostartStale = false, false
    state.system.autostartPath = info
    logs.system(string.format("开机自启已关闭：已从 %s 移除", tostring(info)))
    return true, ""
end

return autostart
