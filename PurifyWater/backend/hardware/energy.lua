--------------------------------------------------------------------------------
-- backend/hardware/energy.lua
--------------------------------------------------------------------------------
-- 【职责】能量仓机器名 -> 全厂可用功率（EU/t）
-- 【不做什么】不预算不调度（domain/power、allocator）、不读组件、不求和
-- 【依赖】shared/constants（只读电压档表 VOLTAGE_TIERS）
-- 【被谁用】backend/jobs（T1）
-- 单仓：machines.energy()，无多仓累计。
-- 功率 = 电压 × 电流：电压 = 8×4^tier；电流 = 1 / multi<N> / 64×4^N（隧道）。
-- 激光仓电流可调，从缓冲容量换算：容量 = 吞吐量 × K（无线 4000，普通 24）。
-- 容量可达 2.25e18 > 2^53，÷K 后相对误差 ~1e-16，可忽略（勿整除/取模）。
--------------------------------------------------------------------------------

local energy = {}
local constants = require("shared.constants") --引入constants.VOLTAGE_TIERS，方便换算

--- 电压名 -> 该档电压（EU/t）；名字里是小写（uev），档表里是大写（UEV）
-- @param word string wirelessenergyhatch后的第一段（如UEV）
-- @return number|nil
local function tierVoltage(word)
    local key = word:lower() --都转为小写比较
    for _, tier in ipairs(constants.VOLTAGE_TIERS) do
        if tier.name:lower() == key then return tier.eu end --都转为小写比较
    end
    return nil
end

-- 激光仓 K：容量 = 吞吐量 × K（无线（含GTNL无线多安仓） 4000，普通 24）
-- @param head string 机器名 `hatch.` 后的第一段（如 energywirelesstunnel7）；没有 `hatch.` 前缀（GTNL）时是整名
-- @return number|nil
local function bufferK(head)
    if head:find("wirelesstunnel", 1, true) then return 4000 end -- 先判 wireless：含 tunnel
    if head:find("tunnel", 1, true) then return 24 end
    if head:find("wirelessenergyhatch", 1, true) then return 4000 end
    return nil
end

--- 四舍五入取整。
-- Lua 5.3 的 ^ 恒给 float；容量超 2^53 被量化，÷K 后带尾差，+0.5 再 floor 恢复整数。
-- @param x number
-- @return number
local function whole(x)
    return math.floor(x + 0.5)
end

--- 单台能量仓贡献的 EU/t（0 = 名字里没有档位，认不出）
-- @param item table { address = string, name = string }
-- @param euMax number|nil getEUMaxStored()：**激光仓才有意义**，由调用方读（本模块不碰组件）
-- @return number 功率
-- @return string|nil 记账依据（仅非名字值时给）
function energy.powerOf(item, euMax)
    local name = tostring(item and item.name or "")

    local gtnltier, gtnlamps = name:match("wirelessenergyhatch(%a+)(%d+)a$")
    local tier = tonumber(name:match("tier%.(%d+)"))

    -- 只看 `hatch.` 后的第一段（如 energywirelesstunnel7），别让 tier 段混进系数识别；
    -- GTNL 的名字没有 `hatch.` 前缀（如 wirelessenergyhatchuev256a），整段当 head 给 bufferK 认
    local head = name:match("^hatch%.([^.]+)") or name

    -- 【必须在这里声明】下面两个分支都要写 voltage/amps，出了分支还要用；声明在分支里会退化成全局 nil
    local voltage, amps, tunnel

    if gtnltier then
        -- GTNL无线能源仓（名字档）：电压名 + `<安>a`，没有 `tier.<N>` 段，故必须在数字档之前判
        voltage = tierVoltage(gtnltier)
        if not voltage then return 0 end
        amps = tonumber(gtnlamps)
    elseif tier then
        local multi = tonumber(head:match("multi(%d+)"))
        tunnel = tonumber(head:match("tunnel(%d+)"))

        amps = 1
        if multi then
            amps = multi
        elseif tunnel then
            amps = 64 * (4 ^ tunnel)
        end

        -- 用 ^ 而不是 math.pow（Lua 5.3+ 已移除 math.pow）
        voltage = 8 * (4 ^ tier)
    else
        return 0
    end

    local nominal = voltage * amps -- 名字值：电流拉满时

    -- 激光仓：名字给的是**上限**，实际电流可能被玩家调小 —— 从缓冲容量精确换算
    if tunnel or gtnltier then
        local k = bufferK(head)
        if k and type(euMax) == "number" and euMax > 0 then
            local exact = euMax / k
            if exact ~= nominal then
                -- 只有被调过才提示
                return whole(exact), string.format(
                    "激光仓限流至 %.0f A（最高 %.0f A）",
                    exact / voltage,
                    amps
                )
            end
            return whole(exact)
        end
    end

    return whole(nominal)
end

return energy