--------------------------------------------------------------------------------
-- backend/store/history.lua
--------------------------------------------------------------------------------
-- 【职责】曲线点的**读与写**（`data/history.dat`）
-- 【不做什么】不算聚合（报表页删了，小时/天桶整条链一起删）
-- 【依赖】backend/store/files、shared/{config,constants,state}
-- 【被谁用】backend/api（界面读）、jobs（T5 写 / 启动时 load）
--
-- 【文件格式】一种行，省略"# 注释"行：
--   P <t> <p> <u> <o> <w1>…<w8>          曲线点
--   一行一条、字段全是数字：解析不需要转义，坏行直接跳过（不许因为一行坏数据整份读不出来）。
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local state     = require("shared.state")
local files     = require("backend.store.files")

local history   = {}

-- 视图缓存：曲线视图只在"点变了"时重建
-- 界面每 0.25 秒取一次视图，而曲线每 30 秒才多一个点：每帧重建 8 等级 × 最多 80 点的数组
--   纯是给 OC 的垃圾回收加活（OC 的 Lua 堆上限由内存条决定，堆一满就在任意一处小分配上报
--   "not enough memory"）。键 = 点数 + 最后一点时刻 + 窗口：三者任一变了才重建。
-- 【只读】调用方只许读，不许改这个表（图表画的时候只读它）。
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

--- 取数组第 i 项（越界给 0，免得解析逻辑到处写判空）
-- @param list table
-- @param index number
-- @return number
local function at(list, index)
    local value = list[index]
    if type(value) ~= "number" then return 0 end
    return value
end

--- 抽一个点（当前快照 -> 曲线点）
-- 原来在 domain/report 里；报表页删掉后只剩抽点一件事，
--   而它本来就是"曲线"的一部分（写盘 / 读盘 / 抽点同一件事）。
-- @return table { t = 时刻, w = {1..8 水量}, p = 全厂可用功率, u = 本轮已用, o = 开着几级 }
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

--- 追加一个点到曲线（容量到上限就丢最老的），T5 调
-- @return table 刚加的点
function history.append()
    local point         = sample()
    local points        = state.chart.points
    points[#points + 1] = point
    local limit         = (CONFIG.CHART and CONFIG.CHART.POINTS) or 80
    while #points > limit do table.remove(points, 1) end
    return point
end

--- 读盘 -> state.chart
-- @return boolean 是否读到内容
-- @return string 说明
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

    -- 【上限】盘上点数超过上限时只留最新的那些：文件是人删得掉、程序却会照着整份读进内存的，
    --   不夹住就等于把内存交给盘上文件决定（旧版本写下的长文件会直接顶爆 Lua 堆）。
    local limit = (CONFIG.CHART and CONFIG.CHART.POINTS) or 80
    if #chart.points > limit then
        local tail = {}
        for i = #chart.points - limit + 1, #chart.points do tail[#tail + 1] = chart.points[i] end
        chart.points = tail
    end

    return points > 0, string.format("历史：%d 个采样点（保留最新 %d 个）", points, #chart.points)
end

--- 写盘（由 T5 在"脏"时调用）
-- @return boolean ok
-- @return string 说明
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

--- 界面用的只读视图（点 -> 各等级的数值序列，图表直接画）
-- 【时间窗口】window = 秒数（os.time 单位，1 游戏日 = CONFIG.CHART.SECONDS_PER_GAME_DAY）：
--   只返回"最后一个采样点往前 window 以内"的点；nil / 0 = 全部。
-- 以最后一个点为基准：游戏暂停时点不再增加，若拿 os.time() 当"现在"，
--   恢复游戏后整条曲线会瞬间滑出窗口（屏幕变空白）。
-- @param window number|nil
-- @return table { times, values, count, span, window }
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
