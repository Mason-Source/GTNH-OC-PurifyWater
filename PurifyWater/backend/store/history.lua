--------------------------------------------------------------------------------
-- backend/store/history.lua
--------------------------------------------------------------------------------
-- 【职责】曲线点读写（data/history.dat）
-- 【不做什么】不算聚合
-- 【依赖】store/files、shared/{config,constants,state}
-- 【被谁用】backend/api、jobs（T5）
--
-- 格式：P <t> <p> <u> <o> <w1>…<w8>；全数字、坏行跳过。
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local state     = require("shared.state")
local files     = require("backend.store.files")

local history   = {}

-- 视图缓存：键 = 点数 + 最后一点时刻 + 窗口，任一变化才重建；调用方只读。
local viewCache = { key = nil, data = nil }

local function path()
    return files.path(CONFIG.FILES.HISTORY)
end

--- 视图缓存键（点数 + 最后一点时刻 + 窗口）
-- @param points table 曲线点数组
-- @param window number|nil
-- @return string
local function viewKey(points, window)
    local n = #points
    return string.format("%d:%d:%s", n, (n > 0) and math.floor(points[n].t) or 0, tostring(window or 0))
end

--- 把一行拆成数字数组（首字段是字母标记）
-- @param line string
-- @return string|nil 标记
-- @return table 数字数组（保证每项都是 number）
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

--- 取数组第 i 项（越界给 0）
-- @param list table
-- @param index number
-- @return number
local function at(list, index)
    local value = list[index]
    if type(value) ~= "number" then return 0 end
    return value
end

--- 抽一个点（当前快照 -> 曲线点）
-- @return table { t = 时刻, w = {1..8 水量}, p = 全厂可用功率, u = 本轮已用, o = 开着几级 }
local function sample()
    local water = {}
    for level = 1, constants.LEVEL_COUNT do water[level] = state.read.fluids()[level] or 0 end
    local opened = 0
    for level = 1, constants.LEVEL_COUNT do
        if state.read.lastPlan()[level] == true then opened = opened + 1 end
    end
    return {
        t = os.time(),
        w = water,
        p = state.read.powerAll(),
        u = state.read.powerAll() - state.read.budget(),
        o = opened
    }
end

--- 追加一个点到曲线（容量到上限就丢最老的），T5 调
-- @return table 刚加的点
function history.append()
    local point = sample()
    state.write.chartAppend(point)
    local points = state.read.chart().points
    local limit  = (CONFIG.CHART and CONFIG.CHART.POINTS) or 80
    if #points > limit then
        local tail = {}
        for i = #points - limit + 1, #points do tail[#tail + 1] = points[i] end
        state.write.chartSetPoints(tail)
    end
    return point
end

--- 读盘 -> chart.points
-- @return boolean 是否读到内容
-- @return string 说明
function history.load()
    local chartPoints = {}

    if not files.exists(path()) then
        state.write.chartSetPoints(chartPoints)
        return false, "没有历史文件"
    end

    local points = 0
    for _, line in ipairs(files.readLines(path())) do
        local mark, nums = numbers(line)
        if mark == "P" and #nums >= 4 + constants.LEVEL_COUNT then
            local w = {}
            for level = 1, constants.LEVEL_COUNT do w[level] = at(nums, 4 + level) end
            chartPoints[#chartPoints + 1] = {
                t = at(nums, 1), p = at(nums, 2), u = at(nums, 3), o = at(nums, 4), w = w
            }
            points = points + 1
        end
    end

    -- 超上限只留最新：整份读进内存，不夹住会顶爆。
    local limit = (CONFIG.CHART and CONFIG.CHART.POINTS) or 80
    if #chartPoints > limit then
        local tail = {}
        for i = #chartPoints - limit + 1, #chartPoints do tail[#tail + 1] = chartPoints[i] end
        chartPoints = tail
    end
    state.write.chartSetPoints(chartPoints)

    return points > 0, string.format("历史：%d 个采样点（保留最新 %d 个）", points, #chartPoints)
end

--- 写盘（T5 每拍调用；全量重写）
-- @return boolean ok
-- @return string 说明
function history.save()
    local chart = state.read.chart()
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
    return true, string.format("历史已写盘（%d 点）", #chart.points)
end

--- 界面只读视图（各等级数值序列）
-- window（秒）只取最后一个点往前窗口内的点；nil/0 = 全部。
-- 以最后一点为基准：暂停时点不再增，避免恢复后曲线滑出窗口。
-- @param window number|nil
-- @return table { times, values, count, span, window }
function history.view(window)
    local points = state.read.chart().points

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
