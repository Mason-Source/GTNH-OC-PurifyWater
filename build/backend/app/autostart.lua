local logs      = require("shared.logs")
local state     = require("shared.state")
local store     = require("backend.store.autostart")
local autostart = {}
function autostart.refresh()
    local info = store.read()
    state.write.setAutostart(info.enabled == true, info.stale == true, info.path)
    if info.enabled then
        logs.system(string.format("开机自启：已开启（%s）", tostring(info.path)))
    elseif info.stale then
        logs.warn(string.format("开机自启指向其它路径：%s（配置页重新勾选可更新）",
            tostring(info.target or "?")))
    end
    if info.manualLine then
        logs.warn("检测到 .shrc 另有手动启动行，开机可能重复启动：" .. tostring(info.manualLine))
    end
    return state.read.autostart()
end
function autostart.toggle()
    if not state.read.autostart() then
        local ok, info = store.enable()
        if not ok then
            local text = "开机自启设置失败：" .. tostring(info)
            logs.warn(text)
            return false, text
        end
        state.write.setAutostart(true, false, info)
        logs.system(string.format("开机自启已开启：%s（下次开机生效）", tostring(info)))
        return true, ""
    end
    local ok, info = store.disable()
    if not ok then
        local text = "开机自启取消失败：" .. tostring(info)
        logs.warn(text)
        return false, text
    end
    state.write.setAutostart(false, false, info)
    logs.system(string.format("开机自启已关闭：已从 %s 移除", tostring(info)))
    return true, ""
end
return autostart
