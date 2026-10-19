--------------------------------------------------------------------------------
-- backend/domain/rates.lua
--------------------------------------------------------------------------------
-- 【职责】速率模型与算账（纯函数，只读 state/constants）
-- 【不做什么】不判定可开、不写盘、不写日志、不下发
-- 【依赖】shared/{config,constants,state}
-- 【被谁用】domain/modes/rate、domain/power.suggest
--
-- 模型：每并行吃 1000L 上一级、产 900L 本级；回流级多吃 90L 换 +15% 成功率
-- （默认等级取 constants.RATE_REFLUX_LEVELS，T1/T2 可由 settings 覆盖）；
-- T6 可选双锂数据收集（基础成功率 0.8 → 0.9）；T7 有增产倍率。
-- 需求从最高在役级向 T1 推：需求ₙ = 权重ₙ + 1000×总并行ₙ₊₁。
--
-- 四条规则：
--   ① 只在役前缀（T1..T_N 连续）参与链条/建议/审计，段外预填不算错不报警。
--   ② λ = min(功率λ, 上限λ)，上限λ = min(cap×台数 ÷ 未缩放总并行)：最紧者定比例。
--   ③ 零权重纯过路级给 ZERO_MARGIN 库存余量，垫取整亏欠。
--   ④ 取整只往下修：先 floor，再 T1→T_N 单向收紧保证产出 ≥ 下游消耗。
-- plan() 纯算无缓存，只在 rate.publish() 受控点调用。
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local state     = require("shared.state")

local rates     = {}

--- 把任意输入规整成允许的 T7 增产倍率（认不出 -> 默认档）
-- @param value any
-- @return number
function rates.acceptBoost(value)
    local v = tonumber(value) or CONFIG.RATES.DEFAULT_T7_BOOST
    for _, option in ipairs(constants.T7_BOOST_OPTIONS) do
        if math.abs(v - option) < 0.001 then return option end
    end
    return CONFIG.RATES.DEFAULT_T7_BOOST
end

--- 该级是否回流（T1/T2/T6）
-- @param level number
-- @return boolean
local function refluxOf(level)
    local configured = state.read.reflux()[level]
    if type(configured) == "boolean" then return configured end
    return constants.RATE_REFLUX_LEVELS[level] == true
end

--- 回流加成后的成功率′（封顶 100%）
-- @param level number
-- @return number 0..1
function rates.successOf(level)
    local s = constants.RATE_SUCCESS[level] or 0
    if level == constants.T6_LEVEL and state.read.t6DualLithium() then
        s = constants.RATE_SUCCESS_DUAL_LITHIUM
    end
    if refluxOf(level) then s = s + constants.RATE_REFLUX_BONUS end
    return math.min(1, s)
end

--- 某级权重（0..MAX；取值时兜底）
-- @param level number
-- @return number
function rates.weightOf(level)
    local w = tonumber(state.read.weights()[level]) or CONFIG.RATES.DEFAULT_WEIGHT
    if w < 0 then w = 0 end
    if w > CONFIG.RATES.MAX_WEIGHT then w = CONFIG.RATES.MAX_WEIGHT end
    return w
end

--- 某级是否需要生产：需求ₙ > 0 ⟺ 存在 k∈[n,top] 使权重ₖ > 0
-- @param level number
-- @return boolean
function rates.wanted(level)
    for k = level, state.serviceTop() do
        if rates.weightOf(k) > 0 then return true end
    end
    return false
end

--- 在役前缀内权重是否全为 0
-- @return boolean
function rates.allZero()
    return not rates.wanted(1)
end

--- 一轮速率算账（纯算、无缓存；仅 rate.publish() 调用）
---@return table { suggest = {[level]=number}, notes = {...} }
--   suggest = 每台建议并行（floor 后 + 单向收紧；在役前缀外恒 0）—— 由 rate.publish() 发布到 state
--   notes   = 审计明细 { {level=, kind="too_small"|"trimmed", ...}, ... }
--   want    = {[level]=number}        -- 每级期望总并行（链条目标，未缩放）
--   limit   = { lambdaPower, lambdaCap }  -- 谁更小：功率λ < 上限λ = 受功率限制；反之 = 被单机上限卡住
function rates.plan()
    local top = state.serviceTop()

    local boost = rates.acceptBoost(state.read.t7Boost())
    local net, weights, counts = {}, {}, {}
    for level = 1, constants.LEVEL_COUNT do
        -- 每并行净产出（L/周期）= 900 × 成功率′ × T7倍率（只对 T7）− 回流
        local gross = constants.RATE_PRODUCE * rates.successOf(level)
        if level == constants.T7_LEVEL then gross = gross * boost end
        net[level]     = gross - (refluxOf(level) and constants.RATE_REFLUX or 0)
        weights[level] = rates.weightOf(level)
        counts[level]  = math.max(0, state.read.plant(level).deployed or 0)
    end

    -- ① 从最高在役级向 T1 推需求；零权重级乘余量
    local margin = 1 + (CONFIG.RATES.ZERO_MARGIN or 0)
    local unitQ, unitDemand, needs = {}, {}, {}
    local nextQ = 0
    for level = top, 1, -1 do
        local carry = constants.RATE_CONSUME * nextQ
        if weights[level] <= 0 and carry > 0 then
            carry = carry * margin   -- 纯过路：给一点正增长余量（见文件头规矩③）
        end
        local demand = weights[level] + carry
        local q      = (net[level] > 0) and (demand / net[level]) or 0
        unitQ[level], unitDemand[level] = q, demand
        needs[level] = demand > 0
        nextQ = q
    end
    for level = 1, constants.LEVEL_COUNT do
        if level > top then
            unitQ[level], unitDemand[level], needs[level] = 0, 0, false
        end
    end

    -- ② λ = min(功率λ, 上限λ)
    local power  = state.read.powerAll()
    local unitPower = 0
    for level = 1, top do
        unitPower = unitPower + unitQ[level] * (constants.POWER_LEVELS[level] or 0)
    end
    local lambdaPower = (unitPower > 0 and power > 0) and (power / unitPower) or 0

    -- 上限λ = min(单机上限×台数 ÷ 期望总并行)
    local lambdaCap = math.huge
    for level = 1, top do
        if unitQ[level] > 0 and counts[level] > 0 then
            local ratio = (constants.parallelCap(level) * counts[level]) / unitQ[level]
            if ratio < lambdaCap then lambdaCap = ratio end
        end
    end
    if lambdaCap == math.huge then lambdaCap = 0 end

    local lambda = math.min(lambdaPower, lambdaCap)

    -- 对外只给：每级建议 + 审计明细
    local suggest, total, notes = {}, {}, {}

    -- ③ 机器粒度取整：每台建议 = floor(λ×总并行 ÷ 台数)
    for level = 1, top do
        local c    = counts[level]
        local raw  = (c > 0) and (lambda * unitQ[level] / c) or 0

        local per  = math.floor(raw)


        suggest[level] = per
        total[level]   = per * c

        -- 功率为 0 另有警告，不逐级报
        if per < 1 and needs[level] and lambda > 0 then
            notes[#notes + 1] = { level = level, kind = "too_small" }
        end
    end
    -- 段外一律 0
    for level = top + 1, constants.LEVEL_COUNT do
        suggest[level], total[level] = 0, 0
    end

    -- ④ T1→T_N 单向收紧（只减不增）：保证产出 ≥ 下游消耗
    for level = 1, top - 1 do
        local c       = counts[level + 1]
        local supply  = total[level] * net[level]
        local maxNext = math.floor(math.max(0, supply) / constants.RATE_CONSUME)
        local pMax    = (c > 0) and math.floor(maxNext / c) or 0

        if suggest[level + 1] > pMax then
            local from = suggest[level + 1]
            suggest[level + 1] = pMax
            total[level + 1]   = pMax * c
            notes[#notes + 1]  = { level = level + 1, kind = "trimmed", from = from, to = pMax }
        end
    end

    -- want = 未缩放期望总并行；limit = 本次限制源（功率/上限）
    return {
        suggest = suggest,
        notes   = notes,
        want    = unitQ,
        limit   = { lambdaPower = lambdaPower, lambdaCap = lambdaCap },
    }
end

return rates
