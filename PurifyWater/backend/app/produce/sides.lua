--------------------------------------------------------------------------------
-- backend/app/produce/sides.lua
--------------------------------------------------------------------------------
-- 【职责】扫描转运器六面、分类输入/目标侧、生成布局签名、配置与清除侧位
-- 【不做什么】不判等级就绪、不查库存、不决定 forceOff
--------------------------------------------------------------------------------

local state      = require("shared.state")
local utils      = require("shared.utils")

local transposer = require("backend.hardware.transposer")
local binding    = require("backend.app.produce.binding")

local sides = {}

local MAX_MISSING_WIDTH = 52

-- true  = 流体目标和物品目标必须同方向
-- false = 两者可以分别选择不同的非来源方向
local SAME_FLUID_ITEM_TARGET = true

--- 物品条目是否相同（name + damage）
local function sameItem(a, b)
    return a ~= nil and b ~= nil
        and a.name == b.name
        and (tonumber(a.damage) or 0) == (tonumber(b.damage) or 0)
end

--- 该面是否含有任一所需物品
local function faceHasRequiredItem(items, requiredItems)
    for _, item in ipairs(items or {}) do
        for _, req in ipairs(requiredItems or {}) do
            if sameItem(item, req) then return true end
        end
    end
    return false
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
            if item.any then
                local hit = false
                for _, name in ipairs(item.any) do
                    if found[name] then hit = true; break end
                end
                if not hit then miss[#miss + 1] = tostring(item.label or "候选流体") end
            else
                local id = item.id or item.fluid
                if id and not found[id] then
                    miss[#miss + 1] = tostring(item.label or id)
                end
            end
        elseif not found[item] then
            miss[#miss + 1] = tostring(item)
        end
    end
    return miss
end

--- 目标候选必须唯一；0 个或多个都不猜
-- @param candidates table<number, boolean>
-- @param label string
-- @return number|nil
-- @return string|nil
local function chooseTarget(candidates, label)
    local picked, count = nil, 0
    for side = 0, 5 do
        if candidates[side] then
            picked, count = side, count + 1
            if count > 1 then
                return nil, "有多个" .. label .. "目标侧，无法确定"
            end
        end
    end
    if picked == nil then
        return nil, "找不到" .. label .. "目标侧（非来源方向）"
    end
    return picked, nil
end

--- 先求来源方向并集，再从非来源方向中分类 target
---@return table|nil config
---@return string|nil reason
function sides.classify(info, requiredFluids, requiredItems)
    local faces = info.faces
    local needFluids = requiredFluids ~= nil and #requiredFluids > 0
    local needItems  = requiredItems ~= nil and #requiredItems > 0

    local sourceSides = {}
    local sources, itemSources, found = {}, {}, {}

    -- 第一遍：来源方向 = 流体来源 ∪ 物品来源
    for side = 0, 5 do
        local face = faces[side]
        if face then
            if needFluids and face.hasFluid then
                sources[#sources + 1] = side
                sourceSides[side] = true
                for _, name in ipairs(face.fluidNames or {}) do
                    found[name] = true
                end
            end

            if needItems and face.itemSize > 0
                and faceHasRequiredItem(face.items, requiredItems) then
                itemSources[#itemSources + 1] = side
                sourceSides[side] = true
            end
        end
    end

    if needFluids then
        local miss = missingFluids(requiredFluids, found)
        if #miss > 0 then
            return nil, "输入侧缺流体：" .. utils.joinLimited(miss, MAX_MISSING_WIDTH)
        end
    end

    if needItems then
        local missItems = {}
        for _, req in ipairs(requiredItems) do
            local hit = false
            for _, side in ipairs(itemSources) do
                local face = faces[side]
                for _, item in ipairs(face and face.items or {}) do
                    if sameItem(item, req) then hit = true; break end
                end
                if hit then break end
            end
            if not hit then missItems[#missItems + 1] = tostring(req.label or req.name) end
        end
        if #missItems > 0 then
            return nil, "输入侧缺物品：" .. utils.joinLimited(missItems, MAX_MISSING_WIDTH)
        end
    end

    -- 第二遍：目标只能来自非来源方向
    local fluidTargets, itemTargets = {}, {}
    for side = 0, 5 do
        local face = faces[side]
        if face and not sourceSides[side] then
            if needFluids and face.fluids and not face.hasFluid then
                fluidTargets[side] = true
            end
            if needItems and face.itemSize > 0
                and not faceHasRequiredItem(face.items, requiredItems) then
                itemTargets[side] = true
            end
        end
    end

    local target, itemTarget
    if needFluids and needItems and SAME_FLUID_ITEM_TARGET then
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
    local config, reason = sides.classify(info, requiredFluids, requiredItems)
    if not config then return false, reason end

    local ok, err = binding.updateSide(machine, config, info.layout)
    if not ok then return false, "侧位落盘失败：" .. tostring(err) end
    state.write.produceSetSub(machine, {
        sides    = config,
        sideFail = nil,
        layout   = info.layout
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
