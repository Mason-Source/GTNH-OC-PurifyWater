--------------------------------------------------------------------------------
-- backend/store/produce.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化绑定表读写：data/produce.txt
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

--- 读绑定表
function produce_table.load()
    local entries, problems = {}, {}
    local seenMachine, seenTransposer = {}, {}

    for _, line in ipairs(files.readLines(path())) do
        local raw = tostring(line)
        if raw:match("^%s*[^#%s]") then
            local level, machine, transposer, rest =
                raw:match("^%s*(%d+)%s+(%S+)%s+(%S+)%s*(.*)$")
            level = tonumber(level)
            if not level or level < 1 or level > constants.LEVEL_COUNT then
                problems[#problems + 1] = "行格式不对（已跳过）：" .. raw
            elseif seenMachine[machine] then
                problems[#problems + 1] = "机器重复绑定（已跳过）：" .. machine
            elseif seenTransposer[transposer] then
                problems[#problems + 1] = "转运器重复绑定（已跳过）：" .. transposer
            else
                local fields = format.parseFields(rest)
                local sides, sideErr = format.parseSides(fields)
                if sideErr then
                    problems[#problems + 1] = string.format("%s（已忽略侧位）：%s", sideErr, raw)
                else
                    seenMachine[machine], seenTransposer[transposer] = true, true
                    entries[#entries + 1] = {
                        level      = level,
                        machine    = machine,
                        transposer = transposer,
                        sides      = sides,
                        layout     = (fields.layout and fields.layout ~= "-") and fields.layout or nil
                    }
                end
            end
        end
    end

    table.sort(entries, format.less)
    return entries, problems
end

--- 写绑定表（原子写；整表重写）
function produce_table.save(entries)
    local lines = {
        "# 制作自动化绑定表（程序写入；一行一台机器：级 机器地址 转运器地址）",
        "# 可选侧位：fluid_target=... fluid_sources=... item_target=... item_sources=... layout=..."
    }
    for _, entry in ipairs(entries or {}) do
        local parts = {
            string.format("%d %s %s",
                entry.level, tostring(entry.machine), tostring(entry.transposer))
        }
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
        lines[#lines + 1] = table.concat(parts, " ")
    end
    return files.writeLines(path(), lines)
end

return produce_table
