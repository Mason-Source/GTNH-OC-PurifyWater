--------------------------------------------------------------------------------
-- backend/store/settings.lua
--------------------------------------------------------------------------------
-- 【职责】**全部可配置项**的读写：data/settings.txt（`键=值` 一行一条，**用户可手改**）
--   目前装着：阈值/勾选（threshold.N / enabled.N）、运行模式（priority）、调度模式（mode）……
-- 【不做什么】不校验业务值（调用方管）、不含默认值（默认值在 shared/config）
-- 【依赖】backend/store/files、shared/config
-- 【被谁用】backend/store/levels_config（阈值/勾选）、main.lua（启动读）、backend/app/plan.lua（切换写）
--
-- 【为什么一个文件装全部配置】配置页能改的东西都收在这里：备份/对比/手改只动一处，
--   格式简单到"加一项 = 加一行"，解析与写回（load / setMany）完全不用改。
--   写失败由调用方决定怎么提示，不影响主流程。
--------------------------------------------------------------------------------

local CONFIG   = require("shared.config")
local files    = require("backend.store.files")

local settings = {}

local function path()
    return files.path(CONFIG.FILES.SETTINGS)
end

--- 读全部设置
-- 【键名】字母/数字/下划线/点（点给 threshold.N、weight.N 这类分级键用）
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

--- 批量写（一次重写整个文件；没提到的键原样保留）
-- 【参数别叫 pairs】名字一撞就把全局 pairs() 盖住，写起来就成了"调用一个表"（实机翻过车）
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

    local lines = { "# 程序配置（全部可手改；改完 5 秒内生效）" }
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
