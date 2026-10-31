-- 制作自动化的侧位分类与槽位逻辑；需求定义由各等级方法提供。
local produce_registry = require("business.produce")

local layout = {}

function layout.requirements(level)
    level = tonumber(level)
    if not produce_registry.has(level) then return nil end
    return produce_registry.requiredFluids(level) or {},
        produce_registry.requiredItems(level) or {}
end

function layout.implemented(level)
    return produce_registry.has(level)
end

local function sameItem(a, b)
    return a ~= nil and b ~= nil
        and a.name == b.name
        and (tonumber(a.damage) or 0) == (tonumber(b.damage) or 0)
end

local function faceHasRequiredItem(items, requiredItems)
    for _, item in ipairs(items or {}) do
        for _, required in ipairs(requiredItems or {}) do
            if sameItem(item, required) then return true end
        end
    end
    return false
end

local function normalizeFace(face)
    local fluids = face and face.fluids
    local items = face and face.items
    local fluidNames, hasFluid = {}, false
    for _, info in ipairs(fluids or {}) do
        if type(info) == "table" and info.fluid then
            fluidNames[#fluidNames + 1] = info.fluid
            hasFluid = true
        elseif type(info) == "string" and info ~= "" then
            fluidNames[#fluidNames + 1] = info
            hasFluid = true
        end
    end
    table.sort(fluidNames)
    return {
        fluids = fluids,
        fluidNames = fluidNames,
        hasFluid = hasFluid,
        items = items or {},
        hasInventory = items ~= nil,
    }
end

local function missingFluids(required, found)
    local missing = {}
    for _, item in ipairs(required or {}) do
        if type(item) == "table" then
            if item.any then
                local hit = false
                for _, name in ipairs(item.any) do
                    if found[name] then hit = true; break end
                end
                if not hit then missing[#missing + 1] = tostring(item.label or "候选流体") end
            else
                local id = item.id or item.fluid
                if id and not found[id] then missing[#missing + 1] = tostring(item.label or id) end
            end
        elseif not found[item] then
            missing[#missing + 1] = tostring(item)
        end
    end
    return missing
end

local function chooseTarget(candidates, label)
    local picked, count = nil, 0
    for side = 0, 5 do
        if candidates[side] then
            picked, count = side, count + 1
            if count > 1 then return nil, "有多个" .. label .. "目标侧，无法确定" end
        end
    end
    if picked == nil then return nil, "找不到" .. label .. "目标侧（非来源方向）" end
    return picked, nil
end

-- 来源方向 = 流体来源 ∪ 物品来源；目标只能来自非来源方向。
function layout.classify(rawFaces, requiredFluids, requiredItems)
    local faces = {}
    for side = 0, 5 do faces[side] = normalizeFace(rawFaces and rawFaces[side]) end

    local needFluids = requiredFluids ~= nil and #requiredFluids > 0
    local needItems = requiredItems ~= nil and #requiredItems > 0
    if not needFluids and not needItems then return nil, "该等级没有侧位需求" end

    local sourceSides, sources, itemSources, found = {}, {}, {}, {}
    for side = 0, 5 do
        local face = faces[side]
        if needFluids and face.hasFluid then
            sources[#sources + 1] = side
            sourceSides[side] = true
            for _, name in ipairs(face.fluidNames) do found[name] = true end
        end
        if needItems and face.hasInventory and faceHasRequiredItem(face.items, requiredItems) then
            itemSources[#itemSources + 1] = side
            sourceSides[side] = true
        end
    end

    if needFluids then
        local missing = missingFluids(requiredFluids, found)
        if #missing > 0 then return nil, "输入侧缺流体：" .. table.concat(missing, "、") end
    end

    if needItems then
        local missing = {}
        for _, required in ipairs(requiredItems) do
            local hit = false
            for _, side in ipairs(itemSources) do
                for _, item in ipairs(faces[side].items) do
                    if sameItem(item, required) then hit = true; break end
                end
                if hit then break end
            end
            if not hit then missing[#missing + 1] = tostring(required.label or required.name) end
        end
        if #missing > 0 then return nil, "输入侧缺物品：" .. table.concat(missing, "、") end
    end

    local fluidTargets, itemTargets = {}, {}
    for side = 0, 5 do
        local face = faces[side]
        if not sourceSides[side] then
            if needFluids and face.fluids and not face.hasFluid then fluidTargets[side] = true end
            if needItems and face.hasInventory
                and not faceHasRequiredItem(face.items, requiredItems) then
                itemTargets[side] = true
            end
        end
    end

    local target, itemTarget
    if needFluids and needItems then
        local common = {}
        for side = 0, 5 do
            if fluidTargets[side] and itemTargets[side] then common[side] = true end
        end
        local reason
        target, reason = chooseTarget(common, "流体/物品共同")
        if target == nil then return nil, reason end
        itemTarget = target
    else
        if needFluids then
            local reason
            target, reason = chooseTarget(fluidTargets, "流体")
            if target == nil then return nil, reason end
        end
        if needItems then
            local reason
            itemTarget, reason = chooseTarget(itemTargets, "物品")
            if itemTarget == nil then return nil, reason end
        end
    end

    return {
        target = target,
        sources = sources,
        itemTarget = itemTarget,
        itemSources = itemSources,
    }, nil
end

local function sortedFluids(face)
    local out = {}
    for _, info in ipairs(face and face.fluids or {}) do
        if type(info) == "table" and info.fluid then out[#out + 1] = info.fluid
        elseif type(info) == "string" and info ~= "" then out[#out + 1] = info end
    end
    table.sort(out)
    return table.concat(out, ",")
end

local function sortedItems(face)
    local out = {}
    for _, item in ipairs(face and face.items or {}) do
        if item.name then
            out[#out + 1] = tostring(item.name) .. ":" .. tostring(tonumber(item.damage) or 0)
        end
    end
    table.sort(out)
    return table.concat(out, ",")
end

local function itemKey(name, damage)
    return tostring(name) .. ":" .. tostring(tonumber(damage) or 0)
end
layout.itemKey = itemKey

local function addEntry(map, key, entry)
    local list = map[key]
    if not list then list = {}; map[key] = list end
    list[#list + 1] = entry
end

function layout.buildSlots(faces, sides, requiredItems, cacheItems)
    local slots = { ready = true, fluid = {}, item = {} }
    for _, side in ipairs((sides and sides.sources) or {}) do
        local face = faces and faces[side]
        for _, info in ipairs(face and face.fluids or {}) do
            if info.fluid then
                addEntry(slots.fluid, info.fluid, { side = side, tank = info.tank })
            end
        end
    end
    if cacheItems then
        local wanted = {}
        for _, required in ipairs(requiredItems or {}) do
            wanted[itemKey(required.name, required.damage)] = true
        end
        for _, side in ipairs((sides and sides.itemSources) or {}) do
            local face = faces and faces[side]
            for _, stack in ipairs(face and face.items or {}) do
                local key = itemKey(stack.name, stack.damage)
                if wanted[key] and (tonumber(stack.size) or 0) > 0 then
                    addEntry(slots.item, key, { side = side, slot = stack.slot })
                end
            end
        end
    end
    return slots
end

function layout.sourcesAvailable(faces, sides, requiredFluids, requiredItems)
    local fluids, items = {}, {}
    for _, side in ipairs((sides and sides.sources) or {}) do
        local face = faces and faces[side]
        for _, info in ipairs(face and face.fluids or {}) do
            if info.fluid and (tonumber(info.amount) or 0) > 0 then fluids[info.fluid] = true end
        end
    end
    for _, side in ipairs((sides and sides.itemSources) or {}) do
        local face = faces and faces[side]
        for _, stack in ipairs(face and face.items or {}) do
            if (tonumber(stack.size) or 0) > 0 then items[itemKey(stack.name, stack.damage)] = true end
        end
    end

    for _, required in ipairs(requiredFluids or {}) do
        local hit = false
        if type(required) == "table" and required.any then
            for _, id in ipairs(required.any) do if fluids[id] then hit = true; break end end
        else
            local id = type(required) == "table" and (required.id or required.fluid) or required
            if id and fluids[id] then hit = true end
        end
        if not hit then return false, tostring(type(required) == "table" and (required.label or required.id) or required) end
    end
    for _, required in ipairs(requiredItems or {}) do
        if not items[itemKey(required.name, required.damage)] then
            return false, tostring(required.label or required.name)
        end
    end
    return true, nil
end
-- 容器拓扑指纹；只描述容器/内容类型，不包含数量，避免缺料被误判为配置变化。
function layout.topology(faces)
    local parts = {}
    for side = 0, 5 do
        local face = faces and faces[side]
        local fluid = face and face.fluids ~= nil and ("[" .. sortedFluids(face) .. "]") or "-"
        local items = face and face.items ~= nil and ("[" .. sortedItems(face) .. "]") or "-"
        parts[#parts + 1] = tostring(side) .. ":" .. fluid .. ":" .. items
    end
    return table.concat(parts, "|")
end

return layout
