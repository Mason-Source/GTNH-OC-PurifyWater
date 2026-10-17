local constants      = require("shared.constants")
local models         = require("shared.models")
local state          = require("shared.state")
local settings       = require("backend.store.settings")
local produce_config = {}
local lastText       = nil
local DEFAULT        = false
local function keyOf(level) return "produce." .. tostring(level) end
local function fingerprint(flags)
    local lines = {}
    for level = 1, constants.LEVEL_COUNT do
        lines[#lines + 1] = string.format("%d=%s", level, flags[level] and "true" or "false")
    end
    return table.concat(lines, "|")
end
local function ensureKeys(snapshot)
    local pairsToSet, missing = {}, 0
    for level = 1, constants.LEVEL_COUNT do
        if snapshot[keyOf(level)] == nil then
            pairsToSet[keyOf(level)] = DEFAULT and "true" or "false"
            missing = missing + 1
        end
    end
    if missing == 0 then return snapshot end
    settings.setMany(pairsToSet)
    for key, value in pairs(pairsToSet) do snapshot[key] = tostring(value) end
    return snapshot
end
function produce_config.load(snapshot)
    snapshot = ensureKeys(snapshot or settings.load() or {})
    local flags = {}
    for level = 1, constants.LEVEL_COUNT do
        flags[level] = models.bool(snapshot[keyOf(level)], DEFAULT)
        state.write.produceSetLevel(level, { enabled = flags[level] })
    end
    local text = fingerprint(flags)
    if text == lastText then return false, "制作自动化开关未变化" end
    lastText = text
    return true, string.format("制作自动化开关已更新（%d 级）", constants.LEVEL_COUNT)
end
function produce_config.set(level, enabled)
    local ok, err = settings.setMany({ [keyOf(level)] = enabled and "true" or "false" })
    if not ok then return false, err end
    state.write.produceSetLevel(level, { enabled = enabled == true })
    local flags = {}
    for n = 1, constants.LEVEL_COUNT do
        flags[n] = state.read.produceLevel(n).enabled == true
    end
    lastText = fingerprint(flags)
    return true, nil
end
return produce_config
