--------------------------------------------------------------------------------
-- PurifyWater/services/history_service.lua
--
-- 定位：水位历史环的采样、查询与持久化服务。
-- 功能：按配置周期采样 T1-T8 水位，维护固定容量环，并周期性或退出时覆写 history.dat。
-- 边界：只处理水位历史；不参与控制计划或前端布局。
--------------------------------------------------------------------------------

local CONFIG = require("shared.config")
local constants = require("shared.constants")
local state = require("services.state")
local storage = require("services.storage")
local clock = require("services.clock")
local log = require("services.log")

local HISTORY = CONFIG.HISTORY or {}
local INTERVAL = HISTORY.INTERVAL or 30
local CAPACITY = HISTORY.POINTS or 80
local SAVE_INTERVAL = HISTORY.SAVE_INTERVAL or 1000
local PATH = HISTORY.PATH or "data/history.dat"

local service = {}
local due = { sample = 0, save = 0 }
local lastObservedAt = nil
local loaded = false

local function history()
    return state.get().output.history
end

local function validWater(values)
    if type(values) ~= "table" then return false end
    for level = 1, constants.LEVEL_COUNT do
        if type(tonumber(values[level])) ~= "number" then return false end
    end
    return true
end

local function append(values)
    local h = history()
    local levelCount = constants.LEVEL_COUNT
    h.head = (h.head % CAPACITY) + 1
    local base = (h.head - 1) * levelCount
    for level = 1, levelCount do
        h.values[base + level] = math.floor(tonumber(values[level]) or 0)
    end
    if h.count < CAPACITY then h.count = h.count + 1 end
    state.bump()
end

local function serialize()
    local h = history()
    local levelCount = constants.LEVEL_COUNT
    local lines = {
        "return {",
        "version = 1,",
        "interval = " .. tostring(INTERVAL) .. ",",
        "capacity = " .. tostring(CAPACITY) .. ",",
        "head = " .. tostring(h.head) .. ",",
        "count = " .. tostring(h.count) .. ",",
        "values = {",
    }
    for slot = 1, CAPACITY do
        local row = {}
        local base = (slot - 1) * levelCount
        for level = 1, levelCount do
            row[level] = tostring(h.values[base + level] or 0)
        end
        lines[#lines + 1] = table.concat(row, ", ") .. ","
    end
    lines[#lines + 1] = "},"
    lines[#lines + 1] = "}"
    return lines
end

local function applyLoaded(value)
    if type(value) ~= "table" then return false, "history root is not a table" end
    local h = history()
    h.capacity = CAPACITY
    h.interval = INTERVAL
    h.values = type(value.values) == "table" and value.values or {}
    h.count = math.max(0, math.min(CAPACITY, tonumber(value.count) or 0))
    h.head = tonumber(value.head) or 0
    if h.head < 0 or h.head > CAPACITY then h.head = h.count end
    return true, nil
end

--- 载入历史环并安排首次采样与保存时间。
function service.load()
    local h = history()
    h.capacity = CAPACITY
    h.interval = INTERVAL
    h.head = 0
    h.count = 0
    h.values = {}

    if storage.exists(PATH) then
        local text = table.concat(storage.readLines(PATH), "\n")
        if text ~= "" then
            local loader = load
            local chunk, compileErr = loader(text)
            if not chunk then
                log.warn("历史载入失败：" .. tostring(compileErr))
            else
                local ok, value = pcall(chunk)
                if not ok then
                    log.warn("历史载入失败：" .. tostring(value))
                else
                    local applied, applyErr = applyLoaded(value)
                    if not applied then log.warn("历史载入失败：" .. tostring(applyErr)) end
                end
            end
        end
    end

    local now = clock.uptime()
    due.sample = now
    due.save = now + SAVE_INTERVAL
    lastObservedAt = nil
    loaded = true
    state.bump()
    return true
end

--- 按周期采样新水位，并按固定间隔保存历史。
function service.step(now)
    if now >= due.sample then
        local water = state.get().facts.water
        local observedAt = tonumber(water.observedAt)
        if validWater(water.value)
            and (observedAt == nil or lastObservedAt == nil or observedAt > lastObservedAt) then
            append(water.value)
            lastObservedAt = observedAt
        end
        due.sample = now + INTERVAL
    end

    if now >= due.save then
        local ok, err = service.save()
        if not ok then log.warn("历史保存失败：" .. tostring(err)) end
        due.save = now + SAVE_INTERVAL
    end
    return false
end

--- 返回下一次采样或保存时间中较早者。
---@param now number 当前时间。
---@return number dueAt 下一次到期时间。
---@diagnostic disable-next-line: unused-local
function service.nextDue(now)
    return math.min(due.sample, due.save)
end

--- 将当前历史环完整覆写到 history.dat。
function service.save()
    if not loaded then return false, "history not loaded" end
    local ok, err = storage.replace(PATH, serialize())
    if not ok then return false, err or "write failed" end
    return true, nil
end

--- 返回按时间顺序展开的只读历史视图。
function service.view()
    local h = history()
    local levelCount = constants.LEVEL_COUNT
    local values = {}
    for level = 1, levelCount do values[level] = {} end
    if h.count > 0 and h.head > 0 then
        local oldest = h.count < CAPACITY and 1 or (h.head % CAPACITY) + 1
        for offset = 0, h.count - 1 do
            local slot = ((oldest - 1 + offset) % CAPACITY) + 1
            local base = (slot - 1) * levelCount
            for level = 1, levelCount do
                values[level][#values[level] + 1] = tonumber(h.values[base + level])
            end
        end
    end
    return {
        count = h.count,
        capacity = CAPACITY,
        interval = INTERVAL,
        windowMinutes = HISTORY.WINDOW_MINUTES or (CAPACITY * INTERVAL / 60),
        values = values,
    }
end

--- 返回历史文件路径。
function service.path() return PATH end
--- 返回历史采样间隔（秒）。
function service.interval() return INTERVAL end
--- 返回历史环容量（点数）。
function service.capacity() return CAPACITY end

return service