--------------------------------------------------------------------------------
-- backend/hardware/energy.lua
--------------------------------------------------------------------------------
-- 【职责】把能量仓**机器名**折算成"全厂可用功率"（EU/t）
-- 【不做什么】不做功率预算与调度（那是 domain/power、domain/allocator）；不读组件；**不做求和**
-- 【依赖】无（**只看名字**，不发组件调用）
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
-- 【只认名字】旧版还要 getInputVoltage / getEUCapacity（含"容量/24""容量/4000"退化），
--   每次扫描多两次组件调用，且分支行为取决于实机返回什么；名字里的 tier 与 multi/tunnel
--   系数已经把电压与电流写全，一个正则即可。
--------------------------------------------------------------------------------

local energy = {}

--- 单台能量仓贡献的 EU/t（0 = 名字里没有 tier，认不出）
-- @param item table { address = string, name = string }
-- @return number
function energy.powerOf(item)
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
    return 8 * (4 ^ tier) * amps
end

return energy
