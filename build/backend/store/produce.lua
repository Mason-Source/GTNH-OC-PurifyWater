local CONFIG       = require("shared.config")
local constants    = require("shared.constants")
local files        = require("backend.store.files")
local produce_table = {}
local SIDE_MIN, SIDE_MAX = 0, 5
local function path()
    return files.path(CONFIG.FILES.PRODUCE)
end
local function less(a, b)
    if a.level ~= b.level then return a.level < b.level end
    return tostring(a.machine) < tostring(b.machine)
end
local function sideText(value)
    local n = tonumber(value)
    if n and n >= SIDE_MIN and n <= SIDE_MAX and n % 1 == 0 then
        return tostring(n)
    end
    return "-"
end
local function listText(list)
    if type(list) ~= "table" or #list == 0 then return "-" end
    local out = {}
    for _, value in ipairs(list) do
        local n = tonumber(value)
        if n and n >= SIDE_MIN and n <= SIDE_MAX and n % 1 == 0 then
            out[#out + 1] = tostring(n)
        end
    end
    if #out == 0 then return "-" end
    table.sort(out, function(a, b) return tonumber(a) < tonumber(b) end)
    return table.concat(out, ",")
end
local function parseSide(text)
    if text == nil or text == "" or text == "-" then return nil, false end
    local n = tonumber(text)
    if n and n >= SIDE_MIN and n <= SIDE_MAX and n % 1 == 0 then
        return n, false
    end
    return nil, true
end
local function parseSideList(text)
    if text == nil or text == "" or text == "-" then return {}, false end
    local out = {}
    for part in tostring(text):gmatch("[^,]+") do
        local n, bad = parseSide(part)
        if bad then return nil, true end
        if n ~= nil then out[#out + 1] = n end
    end
    table.sort(out)
    return out, false
end
local function parseFields(rest)
    local fields = {}
    for token in tostring(rest or ""):gmatch("%S+") do
        local key, value = token:match("^([%w_]+)=(.+)$")
        if key then fields[key] = value end
    end
    return fields
end
local function parseSides(fields)
    local has = fields.fluid_target or fields.fluid_sources
        or fields.item_target or fields.item_sources
    if not has then return nil, nil end
    local fluidTarget, bad = parseSide(fields.fluid_target)
    if bad then return nil, "fluid_target 非法" end
    local fluidSources, badSources = parseSideList(fields.fluid_sources)
    if badSources then return nil, "fluid_sources 非法" end
    local itemTarget, badItem = parseSide(fields.item_target)
    if badItem then return nil, "item_target 非法" end
    local itemSources, badItemSources = parseSideList(fields.item_sources)
    if badItemSources then return nil, "item_sources 非法" end
    fluidSources, itemSources = fluidSources or {}, itemSources or {}
    if fluidTarget == nil and itemTarget == nil
        and #fluidSources == 0 and #itemSources == 0 then
        return nil, nil
    end
    return {
        target      = fluidTarget,
        sources     = fluidSources,
        itemTarget  = itemTarget,
        itemSources = itemSources
    }, nil
end
function produce_table.load()
    local entries, problems          = {}, {}
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
                local fields = parseFields(rest)
                local sides, sideErr = parseSides(fields)
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
    table.sort(entries, less)
    return entries, problems
end
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
        local sides = entry.sides
        if type(sides) == "table"
            and (sides.target ~= nil or sides.itemTarget ~= nil
                or (type(sides.sources) == "table" and #sides.sources > 0)
                or (type(sides.itemSources) == "table" and #sides.itemSources > 0)) then
            parts[#parts + 1] = "fluid_target=" .. sideText(sides.target)
            parts[#parts + 1] = "fluid_sources=" .. listText(sides.sources)
            parts[#parts + 1] = "item_target=" .. sideText(sides.itemTarget)
            parts[#parts + 1] = "item_sources=" .. listText(sides.itemSources)
        end
        if entry.layout and tostring(entry.layout) ~= "" then
            parts[#parts + 1] = "layout=" .. tostring(entry.layout)
        end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    return files.writeLines(path(), lines)
end
return produce_table
