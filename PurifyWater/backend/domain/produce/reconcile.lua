--------------------------------------------------------------------------------
-- backend/domain/produce/reconcile.lua
--------------------------------------------------------------------------------
-- 【职责】把“本轮扫描结果”与活跃绑定 / 删除候选池对账（纯逻辑，不读写文件）
-- 【不做】不碰组件、不写 state、不保存 produce.txt
--------------------------------------------------------------------------------

local constants = require("shared.constants")

local reconcile = {}

local function copyActive(entry)
    return {
        level      = entry.level,
        machine    = entry.machine,
        transposer = entry.transposer,
        sides      = entry.sides,
        layout     = entry.layout
    }
end

local function copyCandidate(entry, miss, observedLevel)
    return {
        level         = entry.level,
        machine       = entry.machine,
        transposer    = entry.transposer,
        sides         = entry.sides,
        layout        = entry.layout,
        miss          = miss,
        observedLevel = observedLevel
    }
end

local function observedLevel(registry, machine)
    for level = 1, constants.LEVEL_COUNT do
        if registry[level] and registry[level][machine] then return level end
    end
    return nil
end

local function evictOldest(list, actions)
    local index
    local oldest = -1
    for i, entry in ipairs(list) do
        local miss = tonumber(entry.miss) or 1
        if miss > oldest then
            index, oldest = i, miss
        end
    end
    local removed = table.remove(list, index)
    actions.deleted[#actions.deleted + 1] = {
        entry  = removed,
        reason = string.format("候选池超过 %d 条，淘汰最旧记录", constants.PRODUCE_MISSING_POOL_MAX)
    }
end

--- 对账一轮
-- @param binds table 活跃绑定
-- @param candidates table 删除候选
-- @param registry table { [level] = { [machine] = true } }
-- @param scanTrusted boolean 本轮扫描是否可信；不可信时完全不推进缺失计数
-- @return table { active, candidates, quarantined, restored, deleted, scanSkipped, changed }
function reconcile.run(binds, candidates, registry, scanTrusted)
    local result = {
        active      = binds or {},
        candidates  = candidates or {},
        quarantined = {},
        restored    = {},
        deleted     = {},
        scanSkipped = not scanTrusted,
        changed     = false,
        dirty       = false
    }
    if not scanTrusted then return result end

    local active, nextCandidates = {}, {}

    -- 活跃绑定：本轮找不到 -> 立刻隔离，但从第 1 轮开始计 miss。
    for _, entry in ipairs(binds or {}) do
        local seenLevel = registry[entry.level] and registry[entry.level][entry.machine]
        if seenLevel then
            active[#active + 1] = entry
        else
            local candidate = copyCandidate(entry, 1, observedLevel(registry, entry.machine))
            nextCandidates[#nextCandidates + 1] = candidate
            result.quarantined[#result.quarantined + 1] = { entry = candidate }
            result.dirty = true
        end
    end

    -- 候选池：同地址 + 同等级重新出现 -> 原样恢复；连续未命中到阈值 -> 删除。
    for _, entry in ipairs(candidates or {}) do
        local seenLevel = registry[entry.level] and registry[entry.level][entry.machine]
        if seenLevel then
            local restored = copyActive(entry)
            active[#active + 1] = restored
            result.restored[#result.restored + 1] = { entry = restored }
            result.dirty = true
        else
            local miss = (tonumber(entry.miss) or 1) + 1
            local observed = observedLevel(registry, entry.machine)
            local candidate = copyCandidate(entry, miss, observed)
            if miss >= constants.PRODUCE_MISSING_SCANS then
                result.deleted[#result.deleted + 1] = {
                    entry  = candidate,
                    reason = string.format("连续 %d 轮未命中", constants.PRODUCE_MISSING_SCANS)
                }
                result.dirty = true
            else
                nextCandidates[#nextCandidates + 1] = candidate
                result.dirty = true
            end
        end
    end

    -- 候选池只保留最近 / 最年轻的 N 条；溢出时淘汰 miss 最大的最旧记录。
    while #nextCandidates > constants.PRODUCE_MISSING_POOL_MAX do
        evictOldest(nextCandidates, result)
    end

    table.sort(active, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        return tostring(a.machine) < tostring(b.machine)
    end)
    table.sort(nextCandidates, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        return tostring(a.machine) < tostring(b.machine)
    end)

    result.active = active
    result.candidates = nextCandidates
    result.changed = #result.quarantined > 0 or #result.restored > 0
        or #result.deleted > 0
    return result
end

return reconcile
