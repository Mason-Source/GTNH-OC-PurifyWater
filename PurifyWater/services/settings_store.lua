-- data/settings.txt 唯一读写入口：键=值，保留未知手改键。
local storage = require("services.storage")

local settings = {}
local PATH = "data/settings.txt"

local function path()
    return PATH
end

function settings.exists()
    return storage.exists(PATH)
end

function settings.load()
    if not storage.exists(PATH) then return nil end
    local out = {}
    for _, line in ipairs(storage.readLines(PATH)) do
        local key, value = tostring(line):match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if key and value ~= "" then out[key] = value end
    end
    return out
end

function settings.setMany(values)
    local all = settings.load() or {}
    for key, value in pairs(values or {}) do
        all[tostring(key)] = tostring(value)
    end

    local keys = {}
    for key in pairs(all) do keys[#keys + 1] = key end
    table.sort(keys)

    local lines = { "# 程序配置（可手改；重启后生效）" }
    for _, key in ipairs(keys) do
        lines[#lines + 1] = string.format("%s=%s", key, all[key])
    end
    return storage.replace(PATH, lines)
end

function settings.set(key, value)
    return settings.setMany({ [tostring(key)] = value })
end

function settings.path()
    return path()
end

return settings
