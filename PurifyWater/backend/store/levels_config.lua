--------------------------------------------------------------------------------
-- backend/store/levels_config.lua
--------------------------------------------------------------------------------
-- 【职责】1-8 级的**阈值 + 勾选**配置：读写 data/settings.txt，并做变更检测
-- 【不做什么】不做业务判断、不认识旧版配置（旧实现的数据一律不管）
-- 【依赖】shared/{config,constants,models,state}、backend/store/settings
-- 【被谁用】main（启动 load）、jobs（T2 每 5 秒 load 一次做变更检测）、
--           backend/api（界面改阈值后 set -> 立刻 load + 广播事件）
--
-- 【键】threshold.N = 阈值（mB 整数）｜enabled.N = 该级是否受用户阈值管理（true/false），N = 1..8。
--   缺键/写坏 -> 用 CONFIG.LEVELS_DEFAULT 兜底，并把默认值补写回 settings.txt（新装直接生成一份）。
-- 【变更检测】把当前规则拼成一段规范文本当指纹（**只看这几个键**）：settings.txt 里别的键
--   （运行模式/优先级/…）变了不会误触发重排；load() 返回内容是否变化，jobs 据此广播事件。
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

--- 缺键就补默认值（新装/手改删键都重新生成这几个键；已存在的值一律不动）
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

--- 读配置 -> state.rules；返回内容是否变化（false = 与上次一致，不必重排）
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

    state.rules = rules
    return true, string.format("阈值配置已更新（%d 级）", constants.LEVEL_COUNT)
end

--- 写入某级的阈值/勾选（界面改完调用；之后 load 会检测到变化）
-- @param level number
-- @param threshold number|nil 不改则传 nil
-- @param enabled boolean|nil 不改则传 nil
-- @return boolean ok
-- @return string|nil 失败原因
function levels_config.set(level, threshold, enabled)
    local current = state.rules[level] or defaultOf(level)
    state.rules[level] = {
        threshold = threshold or current.threshold,
        enabled   = (enabled == nil) and current.enabled or (enabled == true)
    }
    return levels_config.saveAll()
end

--- 把 state.rules 全量写回 settings.txt（只写阈值/勾选这几个键）
-- @return boolean ok
-- @return string|nil 失败原因
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
