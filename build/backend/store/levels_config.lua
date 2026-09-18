local CONFIG        = require("shared.config")
local constants     = require("shared.constants")
local models        = require("shared.models")
local state         = require("shared.state")
local files         = require("backend.store.files")
local levels_config = {}
local lastText      = nil
local function path()
    return files.path(CONFIG.FILES.LEVELS)
end
local function defaultOf(level)
    local d = CONFIG.LEVELS_DEFAULT or {}
    return { threshold = d.threshold or 0, enabled = d.enabled ~= false }
end
function levels_config.ensure()
    if files.exists(path()) then return false end
    local lines = {
        "# 净水厂阈值配置：一行一级  格式 = 等级 阈值 是否勾选",
        "# 勾选 true  = 该级受阈值管理：水位低于阈值就开启，到了阈值就关闭",
        "# 勾选 false = 该级不受阈值管理（只受 5 倍强制线和原料不足两条硬规则约束）",
        "# 阈值 0     = 永不因阈值开启（**新装默认值**，请按需自己改）",
        "# 阈值单位 = mB（1 桶 = 1000）"
    }
    for level = 1, constants.LEVEL_COUNT do
        local d = defaultOf(level)
        lines[#lines + 1] = models.levelRuleLine(level, d.threshold, d.enabled)
    end
    files.writeLines(path(), lines)
    return true
end
function levels_config.load()
    levels_config.ensure()
    local text = files.read(path()) or ""
    if text == lastText then return false, "阈值配置未变化" end
    lastText = text
    local rules, count = {}, 0
    for _, line in ipairs(files.readLines(path())) do
        local level, threshold, enabled = models.levelRule(line)
        if level then
            rules[level] = { threshold = threshold or 0, enabled = enabled ~= false }
            count = count + 1
        end
    end
    for level = 1, constants.LEVEL_COUNT do
        if not rules[level] then rules[level] = defaultOf(level) end
    end
    state.rules = rules
    return true, string.format("阈值配置已更新（%d 行）", count)
end
function levels_config.set(level, threshold, enabled)
    local current = state.rules[level] or defaultOf(level)
    state.rules[level] = {
        threshold = threshold or current.threshold,
        enabled   = (enabled == nil) and current.enabled or (enabled == true)
    }
    return levels_config.saveAll()
end
function levels_config.saveAll()
    local lines = { "# 净水厂阈值配置：一行一级  格式 = 等级 阈值 是否勾选" }
    for level = 1, constants.LEVEL_COUNT do
        local rule = state.rules[level] or defaultOf(level)
        lines[#lines + 1] = models.levelRuleLine(level, rule.threshold, rule.enabled)
    end
    local ok = files.writeLines(path(), lines)
    if ok then lastText = table.concat(lines, "\n") .. "\n" end
    return ok
end
return levels_config
