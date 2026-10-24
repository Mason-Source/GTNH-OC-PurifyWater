--------------------------------------------------------------------------------
-- backend/store/produce.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化绑定表读写：data/produce.txt（活跃绑定 + 删除候选池）
-- 【不做什么】不判业务；行编解码在 store/produce/format.lua
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local files     = require("backend.store.files")
local format    = require("backend.store.produce.format")

local produce_table = {}

local function path()
    return files.path(CONFIG.FILES.PRODUCE)
end

local function validLevel(level)
    return type(level) == "number" and level >= 1 and level <= constants.LEVEL_COUNT
end

--- 读绑定表：活跃绑定和删除候选分开返回
-- 每行格式：级 机器地址 转运器地址 [state=missing miss=N observed=N] [侧位字段]
-- 没有 state 字段的旧行一律视为活跃绑定。
-- @return table active
-- @return table candidates
-- @return table problems
function produce_table.load()
    local entries, candidates = {}, {}
    local problems = {}
    local seenMachine, seenTransposer = {}, {}

    for _, line in ipairs(files.readLines(path())) do
        local raw = tostring(line)
        if raw:match("^%s*[^#%s]") then
            local level, machine, transposer, rest =
                raw:match("^%s*(%d+)%s+(%S+)%s+(%S+)%s*(.*)$")
            level = tonumber(level)
            if not validLevel(level) then
                problems[#problems + 1] = "行格式不对（已跳过）：" .. raw
            elseif seenMachine[machine] then
                problems[#problems + 1] = "机器重复绑定（已跳过）：" .. machine
            elseif seenTransposer[transposer] then
                problems[#problems + 1] = "转运器重复绑定（已跳过）：" .. transposer
            else
                local fields = format.parseFields(rest)
                local status = fields.state or "active"
                if status ~= "active" and status ~= "missing" then
                    problems[#problems + 1] = "绑定状态非法（已跳过）：" .. raw
                else
                    local sides, sideErr = format.parseSides(fields)
                    if sideErr then
                        problems[#problems + 1] = string.format("%s（已忽略侧位）：%s", sideErr, raw)
                    else
                        seenMachine[machine], seenTransposer[transposer] = true, true
                        local entry = {
                            level      = level,
                            machine    = machine,
                            transposer = transposer,
                            sides      = sides,
                            layout     = (fields.layout and fields.layout ~= "-") and fields.layout or nil
                        }
                        if status == "missing" then
                            local miss = tonumber(fields.miss)
                            if not miss or miss < 1 or miss % 1 ~= 0 then
                                miss = 1
                                problems[#problems + 1] =
                                    "候选 miss 字段非法（按 1 处理）：" .. raw
                            end
                            local observed = tonumber(fields.observed)
                            entry.miss = miss
                            entry.observedLevel = validLevel(observed) and observed or nil
                            candidates[#candidates + 1] = entry
                        else
                            entries[#entries + 1] = entry
                        end
                    end
                end
            end
        end
    end

    table.sort(entries, format.less)
    table.sort(candidates, format.less)
    return entries, candidates, problems
end

local function appendFields(parts, entry)
    local s = entry.sides
    if type(s) == "table"
        and (s.target ~= nil or s.itemTarget ~= nil
            or (type(s.sources) == "table" and #s.sources > 0)
            or (type(s.itemSources) == "table" and #s.itemSources > 0)) then
        parts[#parts + 1] = "fluid_target=" .. format.sideText(s.target)
        parts[#parts + 1] = "fluid_sources=" .. format.listText(s.sources)
        parts[#parts + 1] = "item_target=" .. format.sideText(s.itemTarget)
        parts[#parts + 1] = "item_sources=" .. format.listText(s.itemSources)
    end
    if entry.layout and tostring(entry.layout) ~= "" then
        parts[#parts + 1] = "layout=" .. tostring(entry.layout)
    end
end

--- 写绑定表（原子写；活跃绑定和候选池一次整表写回）
function produce_table.save(entries, candidates)
    local lines = {
        "# 制作自动化绑定表（程序写入；一行一台机器：级 机器地址 转运器地址）",
        "# 删除候选：字段 state=missing miss=N；旧行无 state 时视为活跃绑定",
        "# 可选侧位：fluid_target=... fluid_sources=... item_target=... item_sources=... layout=..."
    }

    for _, entry in ipairs(entries or {}) do
        local parts = {
            string.format("%d %s %s",
                entry.level, tostring(entry.machine), tostring(entry.transposer))
        }
        appendFields(parts, entry)
        lines[#lines + 1] = table.concat(parts, " ")
    end

    if candidates and #candidates > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "# --- 删除候选（重新扫到会自动恢复） ---"
        for _, entry in ipairs(candidates) do
            local miss = math.max(1, math.floor(tonumber(entry.miss) or 1))
            local parts = {
                string.format("%d %s %s state=missing miss=%d",
                    entry.level, tostring(entry.machine), tostring(entry.transposer), miss)
            }
            if validLevel(entry.observedLevel) then
                parts[#parts + 1] = "observed=" .. tostring(entry.observedLevel)
            end
            appendFields(parts, entry)
            lines[#lines + 1] = table.concat(parts, " ")
        end
    end

    return files.writeLines(path(), lines)
end

return produce_table
