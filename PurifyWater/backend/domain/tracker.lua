--------------------------------------------------------------------------------
-- backend/domain/tracker.lua
--------------------------------------------------------------------------------
-- 【职责】并行"采样 -> 可信"的唯一判定：同一个值**连续 N 个运行周期**才算数
-- 【不做什么】不写盘（那是 store/records）、不算功率（那是 domain/power）
-- 【依赖】shared/config、shared/state
-- 【被谁用】backend/app/watch（parallel_sample 事件）
--
-- 【按运行周期确认】并行 = "这台机器在一个完整配方里能吃多少水"，周期内恒定、只在周期之间变
--   （刚启动 / 刚改并行时会吐过渡值），所以"连续 N 个**周期**同值"才算稳定；
--   按秒数数（连续 3 次采样 = 15 秒）可能只落在一个周期里。
--
-- 【周期边界】`getWorkProgress` **回落**（本次 < 上次）即新周期开始；单元空闲时进度为 0、
--   周期末回落（见 hardware/probes）。读不到进度时退化为"每 N 次采样算一个周期"
--   （CONFIG.PARALLEL_FALLBACK_SAMPLES），仍能收敛。
--
-- 【周期值取哪一个】取该周期内**最后一次**读到的并行（周期内值恒定，最后一次最接近周期末真值）。
--
-- 【状态】state.tracker[address] = { progress, cycleValue, value, streak, samples, confirmed }
--   progress   上次看到的进度（判断回落用）
--   cycleValue 本周期内最后一次读到的并行（周期结算时作为"这个周期的值"）
--   value      上一个周期结算下来的值（连续比较的基准）
--   streak     已经连续多少个周期同值
--   samples    读不到进度时的采样计数（退化口径用）
--   confirmed  **这台机器被确认过的真实并行**（连续 N 周期同值那一刻记下；详情页逐台展示用）
--------------------------------------------------------------------------------

local CONFIG  = require("shared.config")
local state   = require("shared.state")

local tracker = {}

--- 要连续几个周期同值才算可信
-- @return number
local function limit()
    return math.max(1, CONFIG.PARALLEL_CONFIRM_CYCLES or 3)
end

--- 喂一个采样
-- @param address string 机器地址
-- @param value number 本次读到的并行
-- @param progress number|nil 本次读到的运行进度（判断周期边界；nil = 读不到）
-- @return string "write"|"discard"
-- @return string why 说明（写日志用）
function tracker.feed(address, value, progress)
    if type(value) ~= "number" or value <= 0 then
        tracker.reset(address)
        return "discard", "并行读数无效"
    end

    local t = state.tracker[address]
    if not t then
        -- 首读：只记下本周期代表值，等第一个周期结束（那时才有"一个完整周期"可结算）
        state.tracker[address] = {
            progress   = tonumber(progress),
            cycleValue = value,
            samples    = 1
        }
        return "discard", string.format("首读 %d（等第 1 个运行周期结束）", value)
    end

    t.cycleValue = value -- 本周期内以"最后一次读到的值"为该周期的值

    -- ① 这个周期结束了没？进度回落算结束；读不到进度就按采样次数退化
    local closed = false
    if type(progress) == "number" and type(t.progress) == "number" then
        if progress < t.progress then closed = true end
        t.progress = progress
    else
        t.samples = (t.samples or 0) + 1
        if t.samples >= math.max(1, CONFIG.PARALLEL_FALLBACK_SAMPLES or 24) then
            t.samples = 0
            closed    = true
        end
    end
    if not closed then
        return "discard", string.format("本周期读到 %d（等周期结束）", value)
    end

    -- ② 周期结算：连续几个周期是同值？
    if t.value == value then
        t.streak = (t.streak or 0) + 1
    else
        t.value, t.streak = value, 1
    end
    if t.streak >= limit() then
        -- 确认过就不再每轮重复写盘；下次真的变了再重新数
        t.streak    = 0
        -- 【留一份逐台确认值】记录文件是按**等级**写的（records.save 写 snap.parallel），
        --   详情页要看"每台机器分别"的真实并行，所以这里留一份。
        t.confirmed = value
        return "write", string.format("连续 %d 个运行周期均为 %d", limit(), value)
    end
    return "discard", string.format("周期值 %d（%d/%d 个周期）", value, t.streak, limit())
end

--- 复位某台机器（开关变化 / 停机时报的读数不算数）
-- @param address string
function tracker.reset(address)
    state.tracker[address] = nil
end

--- 忘掉一批机器（机器增删、开关变化时调用）
-- @param list table 机器表数组（{address=...}）或地址数组
function tracker.clear(list)
    for _, item in ipairs(list or {}) do
        local address = (type(item) == "table") and item.address or item
        if address then state.tracker[address] = nil end
    end
end

--- 全清（硬件变更、系统停机时用）
function tracker.resetAll()
    state.tracker = {}
end

return tracker
