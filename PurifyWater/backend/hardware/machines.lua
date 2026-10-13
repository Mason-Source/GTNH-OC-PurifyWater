--------------------------------------------------------------------------------
-- backend/hardware/machines.lua
--------------------------------------------------------------------------------
-- 【职责】T0-8 机器注册表：把 device 收集的地址按 getName() 归类，分出能量仓
-- 【不做什么】不读开关/活动/传感器（那是 probes）；不判断业务
-- 【依赖】shared/constants、hardware/device
-- 【被谁用】hardware/energy、backend/jobs(T1/T3)、store/inventory、frontend（详情页）
--
-- 注册表只存地址，读取走 device.invoke；地址稳定，重扫不错位。
--------------------------------------------------------------------------------

local constants       = require("shared.constants")
local device          = require("backend.hardware.device")

local machines        = {}

-- reg[level] = { { address = , name = }, ... }；level 0 = 净水主机
local reg             = {}
-- 唯一能量仓；多插的按其它记账，不求和
local energyItem      = nil
-- 非净水厂的 gt_machine（计数用）
local otherReg        = {}

-- 能量仓机器名特征（公式见 energy.lua）
local ENERGY_PATTERNS = {
    "hatch.energytunnel", "hatch.energywirelesstunnel",
    "hatch.energymulti", "hatch.energywirelessmulti"
}

--- 是否能量仓（按机器名）
-- @param name string
-- @return boolean
local function isEnergy(name)
    for _, pattern in ipairs(ENERGY_PATTERNS) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end

for level = 0, constants.LEVEL_COUNT do reg[level] = {} end

--- 按名归类，重建注册表（T1 的任务体调用）
-- @return table 摘要 { host, unitTotal, units = {[level]=n}, energy = boolean, other }
function machines.classify()
    for level = 0, constants.LEVEL_COUNT do reg[level] = {} end
    energyItem, otherReg = nil, {}

    for _, address in ipairs(device.machines()) do
        local name = device.name(address)
        if name then
            local level = constants.MACHINE_NAMES[name]
            if level then
                reg[level][#reg[level] + 1] = { address = address, name = name }
            elseif isEnergy(name) then
                -- 单仓：只认第一台，其余入其它
                if energyItem then
                    otherReg[#otherReg + 1] = { address = address, name = name }
                else
                    energyItem = { address = address, name = name }
                end
            else
                otherReg[#otherReg + 1] = { address = address, name = name }
            end
        end
    end
    return machines.summary()
end

--- 扫描摘要
-- @return table { host, unitTotal, units = {[level]=n}, energy = boolean, other }
function machines.summary()
    local units, unitTotal = {}, 0
    for level = 1, constants.LEVEL_COUNT do
        units[level] = #reg[level]
        unitTotal = unitTotal + units[level]
    end
    return {
        host = #reg[0],
        unitTotal = unitTotal,
        units = units,
        energy = energyItem ~= nil,
        other = #otherReg
    }
end

--- 某等级的机器清单（0 = 主机）
-- @param level number
-- @return table 数组（不存在时为空表）
function machines.of(level)
    return reg[level] or {}
end

--- 绑定的能量仓（唯一）
-- @return table|nil { address, name, power? }
function machines.energy()
    return energyItem
end

--- 拓扑清单（落盘用）
-- level：0-8 机器 / E 能量仓 / ? 其它
-- @return table { { level = number|string, address = string, name = string }, ... }
function machines.topology()
    local out = {}
    for level = 0, constants.LEVEL_COUNT do
        for _, m in ipairs(reg[level]) do
            out[#out + 1] = { level = level, address = m.address, name = m.name }
        end
    end
    if energyItem then
        out[#out + 1] = { level = "E", address = energyItem.address, name = energyItem.name }
    end
    for _, m in ipairs(otherReg) do
        out[#out + 1] = { level = "?", address = m.address, name = m.name }
    end
    return out
end

return machines
