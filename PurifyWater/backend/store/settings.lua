--------------------------------------------------------------------------------
-- backend/store/settings.lua
--------------------------------------------------------------------------------
-- 【职责】"永久配置"的读写：程序自己记的偏好（目前只有运行模式 priority）
-- 【不做什么】不校验合法性（调用方管）、不含业务默认值（默认值在 shared/config）
-- 【依赖】backend/store/files、shared/config
-- 【被谁用】main.lua（启动加载）、backend/app/plan.lua（切换时保存）
--
-- 不塞进 levels.txt：那个文件是**给人手改**的（阈值/勾选，格式固定三列）；
--   这个文件是**程序自己记的**，格式 `键=值` 一行一条，加新项只需加一行、解析器不动。
-- 写失败只写一行警告，不影响主流程（下次启动回到 config 默认值）。
--------------------------------------------------------------------------------

local CONFIG   = require("shared.config")
local files    = require("backend.store.files")

local settings = {}

local function path()
    return files.path(CONFIG.FILES.SETTINGS)
end

--- 读全部设置
-- @return table|nil 键值表（文件不存在 -> nil）
function settings.load()
    if not files.exists(path()) then return nil end
    local out = {}
    for _, line in ipairs(files.readLines(path())) do
        local key, value = tostring(line):match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key and value ~= "" then out[key] = value end
    end
    return out
end

--- 写一个值（其余项原样保留）
-- @param key string
-- @param value string|number|boolean
-- @return boolean ok
-- @return string 说明
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
