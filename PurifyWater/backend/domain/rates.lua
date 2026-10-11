--------------------------------------------------------------------------------
-- backend/domain/rates.lua
--------------------------------------------------------------------------------
-- 【职责】速率模式的**模型与算账**（纯函数，只读 state/constants）：
--   权重 -> 在役前缀内的各级总并行 -> 按"最紧的约束"整体缩放 -> 每台整数建议 -> 只往下收紧
-- 【不做什么】不判定能不能开（domain/modes/rate 的事）、不写盘（store 的事）、不写日志、不下发
-- 【依赖】shared/{config,constants,state}
-- 【被谁用】domain/modes/rate（判定/审计/建议）、domain/power.suggest（经 domain/mode 分发）
--
-- 【模型（每并行每周期）】吃上一级 1000L；成功产本级 900L；回流等级（T1/T2/T6）额外吃本级 90L，
--   成功率 +15%（封顶 100%）；T7 有超导粗胚增产倍率（1/1.25/1.5/1.75/2）。
--   每并行净产出 = 900 × 成功率′ × T7倍率 − 90 × 是否回流。
-- 【链条（从最高在役级往 T1 推）】需求ₙ =λ权重ₙ + 1000 × 总并行ₙ₊₁；总并行ₙ = 需求ₙ ÷ 每并行净产出ₙ。
--   权重是"本级净产出"：权重 0 也不代表不生产 —— 下游要吃的那部分由程序自动叠加。
--
-- 【三条硬规矩（2026-10-10 定）】
--   ① **在役前缀**：只有 T1..T_N（从 T1 起连续有机器）参与链条/建议/审计。断点之后（含断点级）
--      物理上不可能运行 —— 若还按权重给它派并行，就会出现"要求某级跑 X、而它的最大可调并行是 0"
--      的无解；预填的权重/阈值一律不算错、不报警（state.serviceTop() 提供这段范围）。
--   ② **谁最紧谁决定缩放**：λ = min(功率λ, 上限λ)，上限λ = min(在役级 cap×台数 ÷ 未缩放总并行)。
--      "最快碰到单机并行上限"的那一级决定整体比例；不再逐级单独夹取（夹取只作数值兜底）。
--   ③ **零权重级留余量**：wₙ = 0 的级是"纯过路"（只为下游生产），它的连续目标 = 下游消耗 × (1+ZERO_MARGIN)，
--     给库存留一点正增长垫住取整亏欠（绝对小数会被取整淹没，所以用比例）。正权重的级不加。
--   ④ **取整只往下修**：先 floor 到机器粒度，再从 T1 往 T_N **单向收紧**
--      Aₙ₊₁ ≤ Aₙ×净产出ₙ ÷ 1000 —— 保证每级"产出 ≥ 下游消耗"（库存不负增长），且总功率只会
--      ≤ 预算（绝不加并行）。【不预留本级自身目标】那是"想要多少"，取整层面略欠账没关系；
--      预留它会把下游过度削掉（实机扫掠发现 T5 被削到 0 就是这条）。代价是下游仍可能被轻微
--      下调（比例在整数层面有偏差），明细进审计的 debug 文本。
-- 【调用受控】plan() **无缓存、纯算**，只在受控点被调用（rate.publish 里）：启动 / 功率变 / 台数变 /
--   权重变 / 倍率变 / 模式切换。结果由 rate.publish() 发布 —— 每级建议 → state.plant(n).suggest，
--   审计明细 → state.planNotes；其余地方一律只读 state，不再触发这里的计算。
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

--- 该级是否回流（硬编码表：T1/T2/T6）
-- @param level number
-- @return boolean
local function refluxOf(level)
    return constants.RATE_REFLUX_LEVELS[level] == true
end

--- 回流加成后的成功率′（封顶 100%）
-- @param level number
-- @return number 0..1
function rates.successOf(level)
    local s = constants.RATE_SUCCESS[level] or 0
    if refluxOf(level) then s = s + constants.RATE_REFLUX_BONUS end
    return math.min(1, s)
end

--- 某级权重（0..MAX；手改/命令都可能写坏，取值时再兜一次）
-- @param level number
-- @return number
function rates.weightOf(level)
    local w = tonumber(state.rates[level]) or CONFIG.RATES.DEFAULT_WEIGHT
    if w < 0 then w = 0 end
    if w > CONFIG.RATES.MAX_WEIGHT then w = CONFIG.RATES.MAX_WEIGHT end
    return w
end

--- 某级"到底需不需要生产"（原 plan().needs 的等价现推，**零成本、不依赖 plan**）
-- 【等价性】需求ₙ = 权重ₙ + 1000×总并行ₙ₊₁，而总并行ₙ₊₁ > 0 ⟺ 需求ₙ₊₁ > 0（各等级净产出恒 > 0）
--   ⇒ 需求ₙ > 0 ⟺ 存在 k ∈ [n, top] 使 权重ₖ > 0
-- @param level number
-- @return boolean
function rates.wanted(level)
    for k = level, state.serviceTop() do
        if rates.weightOf(k) > 0 then return true end
    end
    return false
end

--- 在役前缀内权重是否全为 0（原 plan().allZero 的等价现推）
-- @return boolean
function rates.allZero()
    return not rates.wanted(1)
end

--- 一轮速率算账（**纯算、无缓存**；只在 rate.publish() 里被调用）
---@return table { suggest = {[level]=number}, notes = {...} }
--   suggest = 每台建议并行（floor 后 + 单向收紧；在役前缀外恒 0）—— 由 rate.publish() 发布到 state
--   notes   = 审计明细 { {level=, kind="too_small"|"clip"|"trimmed", ...}, ... }
--   want    = {[level]=number}        -- 每级期望总并行（链条目标，未缩放）
--   limit   = { lambdaPower, lambdaCap }  -- 谁更小：功率λ < 上限λ = 受功率限制；反之 = 被单机上限卡住
function rates.plan()
    local top = state.serviceTop()

    local boost = rates.acceptBoost(state.system.t7Boost)
    local net, weights, counts = {}, {}, {}
    for level = 1, constants.LEVEL_COUNT do
        -- 每并行净产出（L/周期）= 900 × 成功率′ × T7倍率（只对 T7）− 回流
        local gross = constants.RATE_PRODUCE * rates.successOf(level)
        if level == constants.T7_LEVEL then gross = gross * boost end
        net[level]     = gross - (refluxOf(level) and constants.RATE_REFLUX or 0)
        weights[level] = rates.weightOf(level)
        counts[level]  = math.max(0, state.plant(level).deployed or 0)
    end

    -- ① 在役前缀内，从最高的在役级往 T1 推：需求 = 本级权重 + 1000 × 下一级总并行（零权重级再乘余量）
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

    -- ② 缩放：λ = min(功率λ, 上限λ)；上限λ 由"最先撞单机上限"的那一级决定
    local power  = state.power.all or 0
    local unitPower = 0
    for level = 1, top do
        unitPower = unitPower + unitQ[level] * (constants.POWER_LEVELS[level] or 0)
    end
    local lambdaPower = (unitPower > 0 and power > 0) and (power / unitPower) or 0

    -- 上限λ = 最小的"单机上限×台数 ÷ 期望总并行"（谁最紧谁决定整体缩放）
    local lambdaCap = math.huge
    for level = 1, top do
        if unitQ[level] > 0 and counts[level] > 0 then
            local ratio = (constants.parallelCap(level) * counts[level]) / unitQ[level]
            if ratio < lambdaCap then lambdaCap = ratio end
        end
    end
    if lambdaCap == math.huge then lambdaCap = 0 end

    local lambda = math.min(lambdaPower, lambdaCap)

    -- 只对外给两样：每级建议 + 审计明细（λ / 上限归属 / 总并行只在本函数内部用）
    local suggest, total, notes = {}, {}, {}

    -- ③ 机器粒度取整：每台建议 = floor(λ×总并行 ÷ 台数)；逐级夹取只作数值兜底
    for level = 1, top do
        local c    = counts[level]
        local raw  = (c > 0) and (lambda * unitQ[level] / c) or 0
        local cap  = constants.parallelCap(level)
        local per, clip = math.floor(raw), false
        if per > cap then per, clip = cap, true end

        suggest[level] = per
        total[level]   = per * c

        if clip then
            notes[#notes + 1] = { level = level, kind = "clip", want = raw, got = per }
        end
        -- 【没功率时不报"分不到"】功率为 0 另有专门的警告（allocator 那条），逐级刷是噪声
        if per < 1 and needs[level] and lambda > 0 then
            notes[#notes + 1] = { level = level, kind = "too_small" }
        end
    end
    -- 在役前缀外一律 0（未部署 / 断点之后）
    for level = top + 1, constants.LEVEL_COUNT do
        suggest[level], total[level] = 0, 0
    end

    -- ④ 从 T1 往 T_N 单向收紧（只减不增）：只保证"本级产得够下一级吃"（库存不负增长）
    --    收紧后：Aₙ×净产出ₙ ≥ 1000×Aₙ₊₁  ->  任何一级库存都不会负增长，且功率只会更省
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

    -- want  = 每级"期望总并行"（链条目标，未缩放）—— 发布侧据此算"用满功率所需台数"
    -- limit = 这次是谁在限制：功率λ / 上限λ / 决定 λ 的那一级（供发布侧写归因）
    return {
        suggest = suggest,
        notes   = notes,
        want    = unitQ,
        limit   = { lambdaPower = lambdaPower, lambdaCap = lambdaCap },
    }
end

return rates
