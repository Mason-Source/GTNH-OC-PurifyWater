local gtInfodata = {}
local FIELDS = {
    {
        name    = "parallel",
        keys    = { "parallel.current", "parallel" },
        labels  = { "当前并行", "并行数", "当前并联", "current parallel", "并行", "parallel" },
        exclude = { "机器", "数量", "machine", "count" }
    },
    {
        name   = "success",
        keys   = { "success_chance", "success" },
        labels = { "成功几率", "成功率", "成功概率", "success chance", "success rate",
            "成功", "success", "chance" }
    }
}
function gtInfodata.stripColors(line)
    return (tostring(line):gsub("§.", ""))
end
function gtInfodata.stripIndex(line)
    return (tostring(line):gsub("^%s*%d+%s*[=:：%)%.]%s*", "", 1))
end
function gtInfodata.splitLine(line)
    local clean = gtInfodata.stripIndex(gtInfodata.stripColors(line))
    local key, rest = clean:match("^([%w%._]+)\\+(.*)$")
    if key then
        rest = rest:gsub("\\+", " / ")
        return key, (rest:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    if clean:match("^[%w%._]+$") then
        return clean, ""
    end
    return nil, clean
end
function gtInfodata.firstNumber(text)
    if type(text) ~= "string" then return nil end
    local cleaned = text:gsub("(%d),(%d)", "%1%2")
    local numStr = cleaned:match("([%-%+]?%d+%.?%d*[eE]?[%-%+]?%d*)")
    if not numStr then return nil end
    local num = tonumber(numStr)
    if num == nil then return nil end
    return num
end
function gtInfodata.coloredNumber(text, fromPos)
    if type(text) ~= "string" then return nil end
    local i = fromPos or 1
    while true do
        local pos = text:find("§", i, true)
        if not pos then return nil end
        local seg = text:sub(pos + 3)
        local stop = seg:find("§", 1, true)
        if stop then seg = seg:sub(1, stop - 1) end
        local num = gtInfodata.firstNumber(seg)
        if num ~= nil then return num end
        i = pos + 3
    end
end
local function matchLabel(lowerLine, labels)
    for _, label in ipairs(labels or {}) do
        local needle = label:lower()
        local pos = lowerLine:find(needle, 1, true)
        if pos then return pos, #needle end
    end
    return nil, nil
end
local function excluded(lowerLine, field)
    for _, token in ipairs(field.exclude or {}) do
        if lowerLine:find(token:lower(), 1, true) then return true end
    end
    return false
end
local function findField(raw, plain, key)
    if key then
        local lowerKey = key:lower()
        for _, field in ipairs(FIELDS) do
            for _, k in ipairs(field.keys) do
                if lowerKey:find(k:lower(), 1, true) then
                    local kpos = raw:find(key, 1, true)
                    return field, (kpos and (kpos + #key) or 1)
                end
            end
        end
        return nil, nil
    end
    local lowerRaw = raw:lower()
    local lowerPlain = plain:lower()
    for _, field in ipairs(FIELDS) do
        local pos, len = matchLabel(lowerRaw, field.labels)
        if pos and not excluded(lowerPlain, field) then
            return field, (pos + len)
        end
    end
    return nil, nil
end
local function valueAt(raw, from)
    local num = gtInfodata.coloredNumber(raw, from)
    if num ~= nil then return num end
    if raw:find("§", 1, true) then return nil end
    return gtInfodata.firstNumber(raw:sub(from))
end
local function put(info, name, value)
    info[name] = value
end
function gtInfodata.parse(lines)
    local info = {
        parallel = nil,
        success = nil
    }
    if lines == nil then return info end
    local list = lines
    if type(lines) == "string" then
        list = {}
        for line in tostring(lines):gmatch("[^\n]+") do list[#list + 1] = line end
    elseif type(lines) ~= "table" then
        return info
    end
    for _, raw in ipairs(list) do
        local plain = gtInfodata.stripColors(raw)
        local key = gtInfodata.splitLine(plain)
        local field, from = findField(raw, plain, key)
        if field then
            local num = valueAt(raw, from)
            if num ~= nil then put(info, field.name, num) end
        end
    end
    return info
end
return gtInfodata
