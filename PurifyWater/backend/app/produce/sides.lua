--------------------------------------------------------------------------------
-- backend/app/produce/sides.lua
--------------------------------------------------------------------------------
-- 【职责】扫描转运器六面、分类输入/目标侧、生成布局签名、配置与清除侧位
-- 【不做什么】不判等级就绪、不查库存、不决定 forceOff
--------------------------------------------------------------------------------

local state      = require("shared.state")

local transposer = require("backend.hardware.transposer")
local binding    = require("backend.app.produce.binding")

local sides = {}

--- 物品条目是否相同（name + damage）
local function sameItem(a, b)
    return a ~= nil and b ~= nil
        and a.name == b.name
        and (tonumber(a.damage) or 0) == (tonumber(b.damage) or 0)
end

--- 单面签名（流体名 + 物品 name:damage；不看量）
local function signatureOf(side, face)
    local itemNames = {}
    for _, item in ipairs(face.items or {}) do
        itemNames[#itemNames + 1] = string.format("%s:%d",
            tostring(item.name), tonumber(item.damage) or 0)
    end
    table.sort(itemNames)
    return string.format("%d:F[%s]I[%s]", side,
        table.concat(face.fluidNames or {}, ","), table.concat(itemNames, ","))
end

--- 扫描六面；一次生成面数据和整体布局签名
function sides.inspect(address, needItems)
    local faces, parts = {}, {}
    for side = 0, 5 do
        local fluids   = transposer.containers(address, side)
        local itemSize = needItems and transposer.inventorySize(address, side) or nil
        if fluids or itemSize then
            local items = itemSize and transposer.items(address, side, itemSize) or nil
            local fluidNames, hasFluid = {}, false
            for _, item in ipairs(fluids or {}) do
                if item.fluid then
                    fluidNames[#fluidNames + 1] = item.fluid
                    hasFluid = true
                end
            end
            table.sort(fluidNames)
            local face = {
                fluids     = fluids,
                fluidNames = fluidNames,
                items      = items or {},
                itemSize   = itemSize or 0,
                hasFluid   = hasFluid
            }
            faces[side] = face
            parts[#parts + 1] = signatureOf(side, face)
        end
    end
    table.sort(parts)
    return { faces = faces, layout = table.concat(parts, "|") }
end

--- 缺失流体说明
local function missingFluids(required, found)
    local miss = {}
    for _, item in ipairs(required or {}) do
        if type(item) == "table" then
            local hit = false
            for _, name in ipairs(item.any or {}) do
                if found[name] then hit = true; break end
            end
            if not hit then miss[#miss + 1] = tostring(item.label or "?") end
        elseif not found[item] then
            miss[#miss + 1] = tostring(item)
        end
    end
    return miss
end

--- 根据扫描结果分类流体/物品的 target 与 sources
---@return table|nil config
---@return string|nil reason
function sides.classify(info, requiredFluids, requiredItems, preferredFluid, preferredItem)
    local faces = info.faces
    local target, emptyCount, emptySide, sources, found = nil, 0, nil, {}, {}
    local itemTarget, itemSources, itemEmptyCount, itemEmptySide = nil, {}, 0, nil

    for side = 0, 5 do
        local face = faces[side]
        if face then
            if face.fluids then
                if preferredFluid ~= nil and side == preferredFluid then
                    target = side
                elseif face.hasFluid then
                    sources[#sources + 1] = side
                    for _, name in ipairs(face.fluidNames) do found[name] = true end
                else
                    emptyCount = emptyCount + 1
                    emptySide = emptySide or side
                end
            end

            if requiredItems and #requiredItems > 0 and face.itemSize > 0 then
                local contains = false
                for _, item in ipairs(face.items) do
                    for _, req in ipairs(requiredItems) do
                        if sameItem(item, req) then contains = true; break end
                    end
                    if contains then break end
                end
                if preferredItem ~= nil and side == preferredItem then
                    itemTarget = side
                elseif contains then
                    itemSources[#itemSources + 1] = side
                else
                    itemEmptyCount = itemEmptyCount + 1
                    itemEmptySide = itemEmptySide or side
                end
            end
        end
    end

    if requiredFluids and #requiredFluids > 0 then
        if target == nil then
            if emptyCount == 0 then return nil, "找不到空容器（流体输出侧）" end
            if emptyCount > 1 then return nil, "有多个空容器，无法确定流体输出侧" end
            target = emptySide
        end
        local miss = missingFluids(requiredFluids, found)
        if #miss > 0 then return nil, "输入侧缺流体：" .. table.concat(miss, "、") end
    end

    if requiredItems and #requiredItems > 0 then
        if itemTarget == nil then
            if itemEmptyCount == 0 then return nil, "找不到物品输出侧（需要物品存储空间）" end
            if itemEmptyCount > 1 then return nil, "有多个物品输出侧，无法确定" end
            itemTarget = itemEmptySide
        end
        local missItems = {}
        for _, req in ipairs(requiredItems) do
            local hit = false
            for _, side in ipairs(itemSources) do
                for _, item in ipairs(faces[side] and faces[side].items or {}) do
                    if sameItem(item, req) then hit = true; break end
                end
                if hit then break end
            end
            if not hit then missItems[#missItems + 1] = tostring(req.label or req.name) end
        end
        if #missItems > 0 then return nil, "输入侧缺物品：" .. table.concat(missItems, "、") end
    end

    return {
        target      = target,
        sources     = sources,
        itemTarget  = itemTarget,
        itemSources = itemSources
    }, nil
end

--- 扫描并配置一台机器的侧位
function sides.configure(machine, sub, requiredFluids, requiredItems)
    local info = sides.inspect(sub.transposer,
        requiredItems ~= nil and #requiredItems > 0)
    local config, reason = sides.classify(info, requiredFluids, requiredItems,
        sub.sideTarget, sub.itemTarget)
    if not config then return false, reason end

    local ok, err = binding.updateSide(machine, config, info.layout)
    if not ok then return false, "侧位落盘失败：" .. tostring(err) end
    state.write.produceSetSub(machine, {
        sides      = config,
        sideTarget = config.target,
        itemTarget = config.itemTarget,
        sideFail   = nil,
        layout     = info.layout
    })
    return true, nil, config
end

--- 仅计算布局签名
function sides.layoutSignature(sub, needItems)
    return sides.inspect(sub.transposer, needItems).layout
end

--- 清除某台机器的侧位配置
function sides.clear(machine)
    local sub = state.read.produce().subs[machine]
    if not sub then return false, "该机器没有子系统（可能未绑定）" end
    local ok, err = binding.updateSide(machine, nil, nil)
    if not ok then return false, "侧位清空落盘失败：" .. tostring(err) end
    state.write.produceClearSides(machine)
    return true, nil
end

return sides
