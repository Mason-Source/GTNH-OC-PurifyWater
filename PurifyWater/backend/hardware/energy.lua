--------------------------------------------------------------------------------
-- backend/hardware/energy.lua
--------------------------------------------------------------------------------
-- 【职责】能量仓机器名 -> 全厂可用功率（EU/t）
-- 【不做什么】不预算不调度（domain/power、allocator）、不读组件、不求和
-- 【依赖】无
-- 【被谁用】backend/jobs（T1）
-- 单仓：machines.energy()，无多仓累计。
--
-- 功率 = 电压 × 电流：电压 = 8×4^tier；电流 = 1 / multi<N> / 64×4^N（隧道）。
-- 激光仓电流可调，从缓冲容量换算：容量 = 吞吐量 × K（无线 4000，普通 24）。
-- 容量可达 2.25e18 > 2^53，÷K 后相对误差 ~1e-16，可忽略（勿整除/取模）。
--------------------------------------------------------------------------------

local energy = {}

-- 激光仓 K：容量 = 吞吐量 × K（无线 4000，普通 24）
-- @param head string `hatch.` 后的第一段（如 energywirelesstunnel7）
-- @return number|nil
local function bufferK(head)
    if head:find("wirelesstunnel", 1, true) then return 4000 end -- 先判 wireless：含 tunnel
    if head:find("tunnel", 1, true) then return 24 end
    return nil
end

--- 四舍五入取整。
-- Lua 5.3 的 ^ 恒给 float；容量超 2^53 被量化，÷K 后带尾差，+0.5 再 floor 恢复整数。
-- @param x number
-- @return number
local function whole(x)
    return math.floor(x + 0.5)
end

--- 单台能量仓贡献的 EU/t（0 = 名字里没有 tier，认不出）
-- @param item table { address = string, name = string }
-- @param euMax number|nil getEUMaxStored()：**激光仓才有意义**，由调用方读（本模块不碰组件）
-- @return number 功率
-- @return string|nil 记账依据（仅非名字值时给）
function energy.powerOf(item, euMax)
    local name = tostring(item and item.name or "")

    local tier = tonumber(name:match("tier%.(%d+)"))
    if not tier then return 0 end

    -- 只看 hatch. 后第一段，避免 tier 段混入
    local head   = name:match("^hatch%.([^.]+)") or ""

    local amps   = 1
    local multi  = tonumber(head:match("multi(%d+)"))
    local tunnel = tonumber(head:match("tunnel(%d+)"))
    if multi then
        amps = multi
    elseif tunnel then
        amps = 64 * (4 ^ tunnel)
    end

    -- Lua 5.3 用 ^，无 math.pow
    local voltage = 8 * (4 ^ tier)
    local nominal = voltage * amps -- 名字值 = 电流拉满

    -- 激光仓名字值是上限；实际电流可能被调小，用缓冲容量精确换算
    if tunnel then
        local k = bufferK(head)
        if k and type(euMax) == "number" and euMax > 0 then
            local exact = euMax / k
            if exact ~= nominal then
                -- 只有被调过才提示
                return whole(exact), string.format("激光仓限流至 %.0f A（最高 %.0f A）",
                    exact / voltage, amps)
            end
            return whole(exact)
        end
    end

    return whole(nominal)
end

return energy
