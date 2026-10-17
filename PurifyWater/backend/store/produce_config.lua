--------------------------------------------------------------------------------
-- backend/store/produce_config.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化开关：读写 settings.txt 的 produce.N（布尔）
-- 【不做什么】不判业务（就绪性/状态在 domain/produce 与 app/produce）
-- 【依赖】shared/{constants,models,state}、backend/store/settings
-- 【被谁用】backend/app/produce（T2s 对账 / 开关命令）
--
-- 键：produce.N（缺键补默认 false 并补写）；变更检测只看这些键。
--------------------------------------------------------------------------------

local constants      = require("shared.constants")
local models         = require("shared.models")
local state          = require("shared.state")

local settings       = require("backend.store.settings")

local produce_config = {}

local lastText       = nil
local DEFAULT        = false

--- 键名只在这里拼
-- @param level number
-- @return string
local function keyOf(level) return "produce." .. tostring(level) end

--- 指纹（只覆盖 produce.N）
-- @param flags table 等级 -> boolean
-- @return string
local function fingerprint(flags)
    local lines = {}
    for level = 1, constants.LEVEL_COUNT do
        lines[#lines + 1] = string.format("%d=%s", level, flags[level] and "true" or "false")
    end
    return table.concat(lines, "|")
end

--- 缺键补默认（补写 settings.txt；已存在的值不动）
-- @param snapshot table settings.load() 的结果
-- @return table 补完后的快照
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

--- 读配置 -> state.produce.levels[n].enabled；返回是否变化
-- @param snapshot table|nil settings.load() 的结果（不传就自己读一次）
-- @return boolean changed
-- @return string 说明
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

--- 写单级开关（内存 + settings.txt）
-- @param level number
-- @param enabled boolean
-- @return boolean ok
-- @return string|nil 失败原因
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