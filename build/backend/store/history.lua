local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local state     = require("shared.state")
local files     = require("backend.store.files")
local history   = {}
local viewCache = { key = nil, data = nil }
local function path()
    return files.path(CONFIG.FILES.HISTORY)
end
local function viewKey(points, window)
    local n = #points
    return string.format("%d:%d:%s", n, (n > 0) and math.floor(points[n].t) or 0, tostring(window or 0))
end
local function numbers(line)
    local mark, rest = tostring(line):match("^(%a)%s+(.*)$")
    if not mark then return nil end
    local nums = {}
    for token in rest:gmatch("[%d%.%-]+") do
        local value = tonumber(token)
        if value then nums[#nums + 1] = value end
    end
    return mark, nums
end
local function at(list, index)
    local value = list[index]
    if type(value) ~= "number" then return 0 end
    return value
end
local function sample()
    local water = {}
    for level = 1, constants.LEVEL_COUNT do water[level] = state.fluids[level] or 0 end
    local opened = 0
    for level = 1, constants.LEVEL_COUNT do
        if state.lastPlan[level] == true then opened = opened + 1 end
    end
    return {
        t = os.time(),
        w = water,
        p = state.power.all or 0,
        u = (state.power.all or 0) - (state.power.budget or 0),
        o = opened
    }
end
function history.append()
    local point         = sample()
    local points        = state.chart.points
    points[#points + 1] = point
    local limit         = (CONFIG.CHART and CONFIG.CHART.POINTS) or 80
    while #points > limit do table.remove(points, 1) end
    return point
end
function history.load()
    local chart = state.chart
    chart.points = {}
    if not files.exists(path()) then return false, "没有历史文件（从零开始记）" end
    local points = 0
    for _, line in ipairs(files.readLines(path())) do
        local mark, nums = numbers(line)
        if mark == "P" and #nums >= 4 + constants.LEVEL_COUNT then
            local w = {}
            for level = 1, constants.LEVEL_COUNT do w[level] = at(nums, 4 + level) end
            chart.points[#chart.points + 1] = {
                t = at(nums, 1), p = at(nums, 2), u = at(nums, 3), o = at(nums, 4), w = w
            }
            points = points + 1
        end
    end
    local limit = (CONFIG.CHART and CONFIG.CHART.POINTS) or 80
    if #chart.points > limit then
        local tail = {}
        for i = #chart.points - limit + 1, #chart.points do tail[#tail + 1] = chart.points[i] end
        chart.points = tail
    end
    return points > 0, string.format("历史：%d 个采样点（保留最新 %d 个）", points, #chart.points)
end
function history.save()
    local chart = state.chart
    local lines = {
        "# 净水厂历史（自动生成：删掉会重新记录）",
        "# P <时刻> <可用功率> <已用功率> <开着级数> <T1..T8 水量>"
    }
    for _, point in ipairs(chart.points) do
        local nums = { "P", math.floor(point.t), math.floor(point.p or 0),
            math.floor(point.u or 0), point.o or 0 }
        for level = 1, constants.LEVEL_COUNT do
            nums[#nums + 1] = math.floor((point.w and point.w[level]) or 0)
        end
        lines[#lines + 1] = table.concat(nums, " ")
    end
    local ok, err = files.writeLines(path(), lines)
    if not ok then return false, "写历史失败：" .. tostring(err) end
    state.clearDirty("history")
    return true, string.format("历史已写盘（%d 点）", #chart.points)
end
function history.view(window)
    local chart  = state.chart
    local points = chart.points
    local key    = viewKey(points, window)
    if viewCache.key == key and viewCache.data then return viewCache.data end
    local from = 1
    if window and window > 0 and #points > 0 then
        local latest = points[#points].t
        while from < #points and (latest - points[from].t) > window do from = from + 1 end
    end
    local times, values = {}, {}
    for level = 1, constants.LEVEL_COUNT do values[level] = {} end
    for i = from, #points do
        local point = points[i]
        times[#times + 1] = point.t
        for level = 1, constants.LEVEL_COUNT do
            values[level][#values[level] + 1] = (point.w and point.w[level]) or 0
        end
    end
    local result = {
        times  = times,
        values = values,
        count  = #times,
        span   = (#times >= 2) and (times[#times] - times[1]) or 0,
        window = window or 0
    }
    viewCache.key, viewCache.data = key, result
    return result
end
return history
