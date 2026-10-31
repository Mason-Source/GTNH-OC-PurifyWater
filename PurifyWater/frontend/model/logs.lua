-- LogRecord -> LogView：DIAG 静默，其余三级由前端统一加中文前缀。
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