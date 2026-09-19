--------------------------------------------------------------------------------
-- backend/hardware/energy.lua
--------------------------------------------------------------------------------
-- 【职责】把能量仓**机器名**折算成"全厂可用功率"（EU/t）
-- 【不做什么】不做功率预算与调度（那是 domain/power、domain/allocator）；不读组件；**不做求和**
-- 【依赖】无（名字 + 调用方递进来的一个容量数）
-- 【被谁用】backend/jobs（T1）
-- 【只有一台仓】系统只绑一个仓（machines.energy()），没有"多仓累计"这回事
--
-- 【公式】功率 = 电压 × 电流
--   电压 = 8 × 4^tier           —— tier 取名字里的 `tier.<N>`
--   电流 = 1                    默认（如 hatch.energytunnel.tier.7）
--        = multi<N>             多安仓（如 hatch.energymulti4.tier.8 → 4 安）
--        = 64 × 4^<N>           隧道（如 hatch.energywirelesstunnel7.tier.13 → 2^20 安）
-- 【实机样例】hatch.energywirelesstunnel7.tier.13
--   = (8 × 4^13) × (64 × 4^7) = 2^29 × 2^20 = 2^49 = 562949953421312 EU/t
-- 【激光仓（名字带 tunnel）的电流是**可调的**】名字里的 `64 × 4^N` 只是**上限**：
--   所以这类仓改从**缓冲容量**换算：容量 = 吞吐量 × K，K（24或4000） 只跟仓型有关，
--   K 不认识 / 容量读不到 -> 退回名字值（= 电流拉满，即决策 7 的算法）。
-- 【精度】容量可达 2.25e18 > 2^53，double 量化步长约 256 EU；÷K 之后相对误差 ~1e-16，
--   对功率预算无影响（但别拿这个数做整除/取模）。
--------------------------------------------------------------------------------

local energy = {}

-- 激光仓的"缓冲倍数"K：容量 = 吞吐量 × K（实测：普通激光 24、无线激光 4000）
-- @param head string `hatch.` 后的第一段（如 energywirelesstunnel7）
-- @return number|nil
local function bufferK(head)
    if head:find("wirelesstunnel", 1, true) then return 4000 end -- 必须先判它：名字里也含 "tunnel"
    if head:find("tunnel", 1, true) then return 24 end
    return nil
end

--- 出口取整（四舍五入）成 **integer 子类型**
-- 【为什么】功率真值必然是整数（V × 电流 / 容量 ÷ K），但 Lua 5.3 里 `^` 恒给 float、
--   组件读数也是 double，于是 `tostring` 会打 `5368709120000.0` 或 `5.36870912e+14`
-- 【为什么 +0.5】容量超过 2^53 时驱动侧已被量化（步长≈256），除以 K 后可能带 ~0.03 尾差，
--   直接 floor 会掉一位；四舍五入把真值恢复成整数。
-- 【放不下时】math.floor 返回原 float（不报错）—— 实测量级 ≤ 5.6e14，碰不到。
-- @param x number
-- @return number
local function whole(x)
    return math.floor(x + 0.5)
end

--- 单台能量仓贡献的 EU/t（0 = 名字里没有 tier，认不出）
-- @param item table { address = string, name = string }
-- @param euMax number|nil getEUMaxStored()：**激光仓才有意义**，由调用方读（本模块不碰组件）
-- @return number 功率
-- @return string|nil 记账依据 —— 只有"没按名字值"时才给，供日志说明这次功率为什么变了
function energy.powerOf(item, euMax)
    local name = tostring(item and item.name or "")

    local tier = tonumber(name:match("tier%.(%d+)"))
    if not tier then return 0 end

    -- 只看 `hatch.` 后的第一段（如 energywirelesstunnel7），别让 tier 段混进系数识别
    local head   = name:match("^hatch%.([^.]+)") or ""

    local amps   = 1
    local multi  = tonumber(head:match("multi(%d+)"))
    local tunnel = tonumber(head:match("tunnel(%d+)"))
    if multi then
        amps = multi
    elseif tunnel then
        amps = 64 * (4 ^ tunnel)
    end

    -- 用 ^ 而不是 math.pow（Lua 5.3+ 已移除 math.pow）
    local voltage = 8 * (4 ^ tier)
    local nominal = voltage * amps -- 名字值：电流拉满时

    -- 激光仓：名字给的是**上限**，实际电流可能被玩家调小 —— 从缓冲容量精确换算
    if tunnel then
        local k = bufferK(head)
        if k and type(euMax) == "number" and euMax > 0 then
            local exact = euMax / k
            if exact ~= nominal then
                -- 只有真被调过才提示（没调时两者相等，静默）
                return whole(exact), string.format("激光仓限流至 %.0f A（最高 %.0f A）",
                    exact / voltage, amps)
            end
            return whole(exact)
        end
    end

    return whole(nominal)
end

return energy
