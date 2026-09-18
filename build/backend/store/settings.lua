local CONFIG   = require("shared.config")
local files    = require("backend.store.files")
local settings = {}
local function path()
    return files.path(CONFIG.FILES.SETTINGS)
end
function settings.load()
    if not files.exists(path()) then return nil end
    local out = {}
    for _, line in ipairs(files.readLines(path())) do
        local key, value = tostring(line):match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and value ~= "" then out[key] = value end
    end
    return out
end
function settings.set(key, value)
    local all = settings.load() or {}
    all[tostring(key)] = tostring(value)
    local keys = {}
    for k in pairs(all) do keys[#keys + 1] = k end
    table.sort(keys)
    local lines = { "# 程序自己记的偏好（手改也行：改完下次启动生效）" }
    for _, k in ipairs(keys) do
        lines[#lines + 1] = string.format("%s=%s", k, all[k])
    end
    local ok, err = files.writeLines(path(), lines)
    if not ok then return false, tostring(err) end
    return true, string.format("%s=%s", key, all[tostring(key)])
end
return settings
