--------------------------------------------------------------------------------
-- backend/store/produce/format.lua
--------------------------------------------------------------------------------
-- 【职责】produce.txt 行格式：绑定排序、侧位字段编解码
-- 【不做什么】不读写文件、不判业务
--------------------------------------------------------------------------------

local format = {}

local SIDE_MIN, SIDE_MAX = 0, 5

--- 条目排序（先级后机器）
function format.less(a, b)
    if a.level ~= b.level then return a.level < b.level end
    return tostring(a.machine) < tostring(b.machine)
end

--- 侧位数字转文本；无效 / 缺失统一写 -
function format.sideText(value)
    local n = tonumber(value)
    if n and n >= SIDE_MIN and n <= SIDE_MAX and n % 1 == 0 then
        return tostring(n)
    end
    return "-"
end

--- 来源侧列表转稳定文本
function format.listText(list)
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

--- 单个侧位解析；非法值返回第二项 true
local function parseSide(text)
    if text == nil or text == "" or text == "-" then return nil, false end
    local n = tonumber(text)
    if n and n >= SIDE_MIN and n <= SIDE_MAX and n % 1 == 0 then
        return n, false
    end
    return nil, true
end

--- 来源侧列表解析
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

--- 行尾 key=value 字段
function format.parseFields(rest)
    local fields = {}
    for token in tostring(rest or ""):gmatch("%S+") do
        local key, value = token:match("^([%w_]+)=(.+)$")
        if key then fields[key] = value end
    end
    return fields
end

--- 侧位字段解析为统一结构
function format.parseSides(fields)
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

return format
