--------------------------------------------------------------------------------
-- PurifyWater/frontend/model/logs.lua
--
-- 定位：日志展示模型。
-- 功能：过滤 DIAG 记录，为错误、警告和系统消息添加中文前缀并生成稳定 revision。
-- 边界：只读日志记录，不写日志文件。
--------------------------------------------------------------------------------

local logs_model = {}

local LEVELS = {
    error = true,
    warn = true,
    system = true,
    diag = true,
}

local PREFIX = {
    error = "[错误] ",
    warn = "[警告] ",
    system = "[系统] ",
}

--- 把日志记录转换为带中文级别前缀的显示模型。
function logs_model.build(source)
    local entries = {}
    local revision = 0
    for _, record in ipairs((source and source.entries) or {}) do
        local level = LEVELS[record.kind] and record.kind or "system"
        if level ~= "diag" then
            revision = tonumber(record.seq) or revision
            entries[#entries + 1] = {
                seq = tonumber(record.seq) or 0,
                at = tonumber(record.at) or 0,
                kind = level,
                text = (PREFIX[level] or "") .. tostring(record.text or ""),
            }
        end
    end

    return {
        revision = revision,
        entries = entries,
    }
end

return logs_model