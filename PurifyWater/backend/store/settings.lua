--------------------------------------------------------------------------------
-- backend/store/settings.lua
--------------------------------------------------------------------------------
-- 【职责】全部可配置项读写：data/settings.txt（键=值，可手改）
-- 【不做什么】不校验业务值、不含默认值（在 shared/config）
-- 【依赖】backend/store/files、shared/config
-- 【被谁用】levels_config、main.lua、app/plan
--
-- 单文件集中配置，加一项 = 加一行；写失败由调用方提示。
--------------------------------------------------------------------------------

local CONFIG   = require("shared.config")
local files    = require("backend.store.files")

local settings = {}

local function path()
    return files.path(CONFIG.FILES.SETTINGS)
end

--- 读全部设置
-- 键名：字母/数字/下划线/点
-- @return table|nil 键值表（文件不存在 -> nil）
function settings.load()
    if not files.exists(path()) then return nil end
    local out = {}
    for _, line in ipairs(files.readLines(path())) do
        local key, value = tostring(line):match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if key and value ~= "" then out[key] = value end
    end
    return out
end

--- 批量写（重写整个文件；未提键保留）
-- 参数勿叫 pairs：会遮蔽全局函数。
-- @param values table 键 -> 值（值会 tostring）
-- @return boolean ok
-- @return string|nil 失败原因
function settings.setMany(values)
    local all = settings.load() or {}
    for key, value in pairs(values or {}) do
        all[tostring(key)] = tostring(value)
    end

    local keys = {}
    for k in pairs(all) do keys[#keys + 1] = k end
    table.sort(keys)

    local lines = { "# 程序配置（全部可手改；重启后生效）" }
    for _, k in ipairs(keys) do
        lines[#lines + 1] = string.format("%s=%s", k, all[k])
    end
    local ok, err = files.writeLines(path(), lines)
    if not ok then return false, tostring(err) end
    return true
end

--- 写一个值（其余项原样保留）
-- @param key string
-- @param value string|number|boolean
-- @return boolean ok
-- @return string 说明
function settings.set(key, value)
    local ok, err = settings.setMany({ [tostring(key)] = value })
    if not ok then return false, err end
    return true, string.format("%s=%s", tostring(key), tostring(value))
end

return settings
