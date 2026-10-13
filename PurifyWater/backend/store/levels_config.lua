--------------------------------------------------------------------------------
-- backend/store/levels_config.lua
--------------------------------------------------------------------------------
-- 【职责】1-8 级阈值 + 勾选配置：读写 settings.txt 并变更检测
-- 【不做什么】不判业务
-- 【依赖】shared/{config,constants,models,state}、backend/store/settings
-- 【被谁用】main、jobs（T2）、backend/api
--
-- 键：threshold.N（mB）/ enabled.N；缺键用 CONFIG.LEVELS_DEFAULT 兜底并补写。
-- 变更检测只看这两个键的规范文本，settings 里其它键变化不触发。
--------------------------------------------------------------------------------

local CONFIG        = require("shared.config")
local constants     = require("shared.constants")
local models        = require("shared.models")
local state         = require("shared.state")

local settings      = require("backend.store.settings")

local levels_config = {}

local lastText      = nil

--- 阈值键 / 勾选键（键名只在这里拼）
local function thresholdKey(level) return "threshold." .. tostring(level) end
local function enabledKey(level)   return "enabled."   .. tostring(level) end

--- 默认值（用户没给阈值时用；见 shared/config.LEVELS_DEFAULT）
-- @param level number
-- @return table { threshold, enabled }
local function defaultOf(level)
    local d = CONFIG.LEVELS_DEFAULT or {}
    return { threshold = d.threshold or 0, enabled = d.enabled ~= false }
end

--- 规则表 -> 指纹文本（只覆盖阈值/勾选，用于变更检测）
-- @param rules table
-- @return string
local function fingerprint(rules)
    local lines = {}
    for level = 1, constants.LEVEL_COUNT do
        local rule = rules[level] or defaultOf(level)
        lines[#lines + 1] = string.format("%d|%d|%s", level,
            math.floor(tonumber(rule.threshold) or 0), rule.enabled and "true" or "false")
    end
    return table.concat(lines, "\n")
end

--- 缺键补默认值；已存在的值不动
-- @param snapshot table settings.load() 的结果
-- @return table 补完后的快照（内存里合并，不再读盘）
-- @return number 补了几个键（0 = 没写盘）
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

--- 读配置 -> config.rules；返回是否变化
-- @param snapshot table|nil 已读好的 settings 表（周期扫描一次读全后共用；不传就自己读一次）
-- @return boolean changed
-- @return string 说明
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

    state.write.setRules(rules)
    return true, string.format("阈值配置已更新（%d 级）", constants.LEVEL_COUNT)
end

--- 写入单级阈值/勾选
-- @param level number
-- @param threshold number|nil 不改则传 nil
-- @param enabled boolean|nil 不改则传 nil
-- @return boolean ok
-- @return string|nil 失败原因
function levels_config.set(level, threshold, enabled)
    local current = state.read.rules()[level] or defaultOf(level)
    state.write.setRuleLevel(level, {
        threshold = threshold or current.threshold,
        enabled   = (enabled == nil) and current.enabled or (enabled == true)
    })
    return levels_config.saveAll()
end

--- 把 config.rules 全量写回 settings.txt（只写阈值/勾选这几个键）
-- @return boolean ok
-- @return string|nil 失败原因
function levels_config.saveAll()
    local pairsToSet = {}
    for level = 1, constants.LEVEL_COUNT do
        local rule = state.read.rules()[level] or defaultOf(level)
        pairsToSet[thresholdKey(level)] = math.floor(tonumber(rule.threshold) or 0)
        pairsToSet[enabledKey(level)]   = rule.enabled and "true" or "false"
    end

    local ok, err = settings.setMany(pairsToSet)
    if not ok then return false, err end
    lastText = fingerprint(state.read.rules())
    return true
end

return levels_config
