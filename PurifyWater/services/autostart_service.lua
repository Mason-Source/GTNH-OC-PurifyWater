-- 开机自启用例：启动读回 .shrc 状态，按钮负责写/删标记块并同步 state。
local state = require("services.state")
local log = require("services.log")
local store = require("services.autostart_store")

local service = {}

local function apply(info)
    local settings = state.get().settings
    settings.autostart = info.enabled == true
    settings.autostartStale = info.stale == true
    settings.autostartPath = info.path
    state.bump()
end

function service.refresh()
    local info = store.read()
    apply(info)

    if info.enabled then
        log.system(string.format("开机自启：已开启（%s）", tostring(info.path)))
    elseif info.stale then
        log.warn(string.format("开机自启指向其它路径：%s（配置页重新勾选可更新）",
            tostring(info.target or "-")))
    end
    if info.manualLine then
        log.warn("检测到 .shrc 另有手动启动行，开机可能重复启动：" .. tostring(info.manualLine))
    end
    return info.enabled == true
end

function service.toggle()
    local info = store.read()
    if not info.enabled then
        local ok, result = store.enable()
        if not ok then
            local text = "开机自启设置失败：" .. tostring(result)
            log.warn(text)
            return false, text
        end
        apply({ enabled = true, stale = false, path = result })
        log.system(string.format("开机自启已开启：%s（下次开机生效）", tostring(result)))
        return true, ""
    end

    local ok, result = store.disable()
    if not ok then
        local text = "开机自启取消失败：" .. tostring(result)
        log.warn(text)
        return false, text
    end
    apply({ enabled = false, stale = false, path = result })
    log.system(string.format("开机自启已关闭：已从 %s 移除", tostring(result)))
    return true, ""
end

function service.handle(name)
    if name ~= "autostart_toggle" then return false end
    local ok, err = service.toggle()
    return true, ok, err
end

return service
