-- data/produce.txt：制作自动化绑定表；兼容 V1 的 state/miss 与侧位字段。
local constants = require("shared.constants")
local storage = require("services.storage")

local produce_store = {}
local PATH = "data/produce.txt"
local SIDE_MIN, SIDE_MAX = 0, 5

local function validLevel(level)
    return type(level) == "number" and level >= 1 and level <= constants.LEVEL_COUNT
end

local function parseFields(rest)
    local fields = {}
    for token in tostring(rest or ""):gmatch("%S+") do
        local key, value = token:match("^([%w_]+)=(.+)$")
        if key then fields[key] = value end
    end
    return fields
end

local function parseSide(text)
    if text == nil or text == "" or text == "-" then return nil, false end
    local number = tonumber(text)
    if number and number >= SIDE_MIN and number <= SIDE_MAX and number % 1 == 0 then
        return number, false
    end
    return nil, true
end

local function parseSideList(text)
    if text == nil or text == "" or text == "-" then return {}, false end
    local out = {}
    for part in tostring(text):gmatch("[^,]+") do
        local number, bad = parseSide(part)
        if bad then return nil, true end
        if number ~= nil then out[#out + 1] = number end
    end
    table.sort(out)
    return out, false
end

local function parseSides(fields)
    local has = fields.fluid_target or fields.fluid_sources
        or fields.item_target or fields.item_sources
    if not has then return nil, nil end

    local target, bad = parseSide(fields.fluid_target)
    if bad then return nil, "fluid_target 非法" end
    local sources, badSources = parseSideList(fields.fluid_sources)
    if badSources then return nil, "fluid_sources 非法" end
    local itemTarget, badItem = parseSide(fields.item_target)
    if badItem then return nil, "item_target 非法" end
    local itemSources, badItemSources = parseSideList(fields.item_sources)
    if badItemSources then return nil, "item_sources 非法" end

    sources, itemSources = sources or {}, itemSources or {}
    if target == nil and itemTarget == nil and #sources == 0 and #itemSources == 0 then
        return nil, nil
    end
    return {
        target = target,
        sources = sources,
        itemTarget = itemTarget,
        itemSources = itemSources,
    }, nil
end

local function less(a, b)
    if a.level ~= b.level then return a.level < b.level end
    return tostring(a.machine) < tostring(b.machine)
end

function produce_store.load()
    local active, candidates, problems = {}, {}, {}
    local seenMachine, seenTransposer = {}, {}
    for _, line in ipairs(storage.readLines(PATH)) do
        local raw = tostring(line)
        if raw:match("^%s*[^#%s]") then
            local level, machine, address, rest =
                raw:match("^%s*(%d+)%s+(%S+)%s+(%S+)%s*(.*)$")
            level = tonumber(level)
            if not validLevel(level) then
                problems[#problems + 1] = "行格式不对（已跳过）：" .. raw
            elseif seenMachine[machine] then
                problems[#problems + 1] = "机器重复绑定（已跳过）：" .. machine
            elseif seenTransposer[address] then
                problems[#problems + 1] = "转运器重复绑定（已跳过）：" .. address
            else
                local fields = parseFields(rest)
                local status = fields.state or "active"
                if status ~= "active" and status ~= "missing" then
                    problems[#problems + 1] = "绑定状态非法（已跳过）：" .. raw
                else
                    local sides, sideErr = parseSides(fields)
                    if sideErr then
                        problems[#problems + 1] = string.format("%s（已忽略侧位）：%s", sideErr, raw)
                    else
                        seenMachine[machine], seenTransposer[address] = true, true
                        local rate = tonumber(fields.rate)
                        local entry = {
                            level = level,
                            machine = machine,
                            transposer = address,
                            rate = (rate and rate > 0) and rate or nil,
                            sides = sides,
                        }
                        if status == "missing" then
                            local miss = tonumber(fields.miss)
                            entry.miss = (miss and miss >= 1 and miss % 1 == 0) and miss or 1
                            candidates[#candidates + 1] = entry
                        else
                            active[#active + 1] = entry
                        end
                    end
                end
            end
        end
    end
    table.sort(active, less)
    table.sort(candidates, less)
    return active, candidates, problems
end

local function sideText(value)
    local number = tonumber(value)
    if number and number >= SIDE_MIN and number <= SIDE_MAX and number % 1 == 0 then
        return tostring(number)
    end
    return "-"
end

local function listText(list)
    local out = {}
    for _, value in ipairs(list or {}) do
        local number = tonumber(value)
        if number and number >= SIDE_MIN and number <= SIDE_MAX and number % 1 == 0 then
            out[#out + 1] = tostring(number)
        end
    end
    if #out == 0 then return "-" end
    table.sort(out, function(a, b) return tonumber(a) < tonumber(b) end)
    return table.concat(out, ",")
end

local function appendRate(parts, entry)
    local rate = tonumber(entry.rate)
    if rate and rate > 0 then parts[#parts + 1] = "rate=" .. tostring(rate) end
end

local function appendSides(parts, entry)
    local sides = entry.sides
    if type(sides) ~= "table" then return end
    if sides.target == nil and sides.itemTarget == nil
        and #(sides.sources or {}) == 0 and #(sides.itemSources or {}) == 0 then
        return
    end
    parts[#parts + 1] = "fluid_target=" .. sideText(sides.target)
    parts[#parts + 1] = "fluid_sources=" .. listText(sides.sources)
    parts[#parts + 1] = "item_target=" .. sideText(sides.itemTarget)
    parts[#parts + 1] = "item_sources=" .. listText(sides.itemSources)
end

local function buildLines(active, candidates)
    local lines = {
        "# 制作自动化绑定表（程序写入；一行一台机器：级 机器地址 转运器地址）",
        "# missing：字段 state=missing miss=N；连续 3 次组件扫描找不到后删除",
        "# 转运器速率：rate=L/s；可选侧位：fluid_target=... fluid_sources=... item_target=... item_sources=...",
    }
    for _, entry in ipairs(active or {}) do
        local parts = { string.format("%d %s %s", entry.level, entry.machine, entry.transposer) }
        appendRate(parts, entry)
        appendSides(parts, entry)
        lines[#lines + 1] = table.concat(parts, " ")
    end
    if candidates and #candidates > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "# --- missing（重新扫到会自动恢复） ---"
        for _, entry in ipairs(candidates) do
            local miss = math.max(1, math.floor(tonumber(entry.miss) or 1))
            local parts = {
                string.format("%d %s %s state=missing miss=%d",
                    entry.level, entry.machine, entry.transposer, miss),
            }
            appendRate(parts, entry)
            appendSides(parts, entry)
            lines[#lines + 1] = table.concat(parts, " ")
        end
    end
    return lines
end

function produce_store.save(active, candidates)
    local lines = buildLines(active, candidates)
    local current = storage.readLines(PATH)
    local nonempty = {}
    for _, line in ipairs(current) do
        if line ~= "" then nonempty[#nonempty + 1] = line end
    end
    local expected = {}
    for _, line in ipairs(lines) do
        if line ~= "" then expected[#expected + 1] = line end
    end
    if table.concat(nonempty, "\n") == table.concat(expected, "\n") then
        return true, false
    end
    local ok, err = storage.replace(PATH, lines)
    if not ok then return false, err end
    return true, true
end

function produce_store.path()
    return PATH
end

return produce_store
