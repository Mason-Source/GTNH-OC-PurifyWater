--------------------------------------------------------------------------------
-- backend/store/levels_config.lua
--------------------------------------------------------------------------------
-- 【职责】`data/levels.txt`（每级的阈值 + 勾选）的读写与变更检测
-- 【依赖】backend/store/files、shared/{config,models,state,constants}
-- 【被谁用】main（启动时 load）、jobs（T2 之前 load 一次检测文件变化）、前端（改阈值后写回）
--
-- 【文件】一行一级：`等级 阈值 勾选`    例：`3 1000000000000 true`
-- 【新装】文件不存在时 ensure() 生成一份：**每级阈值 0 + 全部勾选**（见 config.LEVELS_DEFAULT）。
--   阈值 0 = 永不因阈值开启 -> 刚接入时只有 5 倍强制线可能开机，等用户在配置页设数。
-- 【变更检测】记住上次读到的原文；文件内容变了才重新解析并返回 true
--   -> jobs 据此广播 level_rules_changed，而不是每 5 秒无脑重排
--------------------------------------------------------------------------------

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

--- 默认值（用户没给阈值时用；见 shared/config.LEVELS_DEFAULT）
-- @param level number
-- @return table { threshold, enabled }
local function defaultOf(level)
    local d = CONFIG.LEVELS_DEFAULT or {}
    return { threshold = d.threshold or 0, enabled = d.enabled ~= false }
end

--- 文件不存在则按默认值生成一份（用户可直接编辑）
-- @return boolean 是否新建
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

--- 读文件 -> state.rules
-- @return boolean 内容是否变化（false = 与上次一致，不必重排）
-- @return string 说明
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
    -- 缺行的等级用默认值补齐（文件被手改坏也不至于整级消失）
    for level = 1, constants.LEVEL_COUNT do
        if not rules[level] then rules[level] = defaultOf(level) end
    end
    state.rules = rules
    return true, string.format("阈值配置已更新（%d 行）", count)
end

--- 写入某级的阈值/勾选（界面改完调用；之后 load 会检测到变化）
-- @param level number
-- @param threshold number|nil 不改则传 nil
-- @param enabled boolean|nil 不改则传 nil
-- @return boolean ok
function levels_config.set(level, threshold, enabled)
    local current = state.rules[level] or defaultOf(level)
    state.rules[level] = {
        threshold = threshold or current.threshold,
        enabled   = (enabled == nil) and current.enabled or (enabled == true)
    }
    return levels_config.saveAll()
end

--- 把 state.rules 全量写回文件
-- @return boolean ok
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
