local CONFIG        = require("shared.config")
local constants     = require("shared.constants")
local models        = require("shared.models")
local state         = require("shared.state")
local settings      = require("backend.store.settings")
local levels_config = {}
local lastText      = nil
local function thresholdKey(level) return "threshold." .. tostring(level) end
local function enabledKey(level)   return "enabled."   .. tostring(level) end
local function defaultOf(level)
    local d = CONFIG.LEVELS_DEFAULT or {}
    return { threshold = d.threshold or 0, enabled = d.enabled ~= false }
end
local function fingerprint(rules)
    local lines = {}
    for level = 1, constants.LEVEL_COUNT do
        local rule = rules[level] or defaultOf(level)
        lines[#lines + 1] = string.format("%d|%d|%s", level,
            math.floor(tonumber(rule.threshold) or 0), rule.enabled and "true" or "false")
    end
    return table.concat(lines, "\n")
end
local function ensureKeys(snapshot)
    local pairsToSet, missing = {}, 0
    for level = 1, constants.LEVEL_COUNT do
        local d = defaultOf(level)
        if snapshot[thresholdKey(level)] == nil then
            pairsToSet[thresholdKey(level)] = math.floor(tonumber(d.threshold) or 0)
            missing = missing + 1
        end
        if snapshot[enabledKey(level)] == nil then
            pairsToSet[enabledKey(level)] = d.enabled and "true" or "false"
            missing = missing + 1
        end
    end
    if missing == 0 then return snapshot, 0 end
    settings.setMany(pairsToSet)
    for key, value in pairs(pairsToSet) do snapshot[key] = tostring(value) end
    return snapshot, missing
end
function levels_config.load(snapshot)
    snapshot = ensureKeys(snapshot or settings.load() or {})
    local rules = {}
    for level = 1, constants.LEVEL_COUNT do
        local d         = defaultOf(level)
        local threshold = tonumber(snapshot[thresholdKey(level)]) or d.threshold
        rules[level] = {
            threshold = threshold,
            enabled   = models.bool(snapshot[enabledKey(level)], d.enabled)
        }
    end
    local text = fingerprint(rules)
    if text == lastText then return false, "阈值配置未变化" end
    lastText   = text
    state.rules = rules
    return true, string.format("阈值配置已更新（%d 级）", constants.LEVEL_COUNT)
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
    local pairsToSet = {}
    for level = 1, constants.LEVEL_COUNT do
        local rule = state.rules[level] or defaultOf(level)
        pairsToSet[thresholdKey(level)] = math.floor(tonumber(rule.threshold) or 0)
        pairsToSet[enabledKey(level)]   = rule.enabled and "true" or "false"
    end
    local ok, err = settings.setMany(pairsToSet)
    if not ok then return false, err end
    lastText = fingerprint(state.rules)
    return true
end
return levels_config
