--------------------------------------------------------------------------------
-- PurifyWater/services/settings_store.lua
--
-- 定位：data/settings.txt 的唯一读写入口。
-- 功能：以 key=value 文本加载设置，排序写回，并保留未知的手改键。
-- 边界：不校验业务取值范围；校验由 config_service 负责。
--------------------------------------------------------------------------------

local storage = require("services.storage")

local settings = {}
local PATH = "data/settings.txt"

local function path()
    return PATH
end

--- 判断 settings.txt 是否存在。
function settings.exists()
    return storage.exists(PATH)
end

--- 读取并解析 key=value 设置表。
function settings.load()
    if not storage.exists(PATH) then return nil end
    local out = {}
    for _, line in ipairs(storage.readLines(PATH)) do
        local key, value = tostring(line):match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if key and value ~= "" then out[key] = value end
    end
    return out
end

--- 合并多个设置键，排序后原子替换 settings.txt。
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

--- 写入或更新单个设置键。
function settings.set(key, value)
    return settings.setMany({ [tostring(key)] = value })
end

--- 返回设置文件路径。
function settings.path()
    return path()
end

return settings
