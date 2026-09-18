--------------------------------------------------------------------------------
-- backend/hardware/device.lua
--------------------------------------------------------------------------------
-- 【职责】按名字找组件并缓存：ME 网络接口（流体）、网卡/隧道；以及枚举全部 gt_machine
-- 【不做什么】不读业务状态量（那是 probes / energy / fluid），不判断业务
-- 【依赖】component
-- 【被谁用】hardware/{machines,energy,fluid,net}、backend/jobs(T1)
--
-- 缓存的意义：`component.proxy` 每次调用都要过一次组件表，而 ME 接口每 5 秒读一次水量；
--   硬件重扫（T1）时调 device.invalidate() 重取。
--------------------------------------------------------------------------------

local component      = require("component")

local device         = {}

-- ME 网络接口的候选组件名（实测三选一，按顺序找；来源：v2 实机验证）
local ME_CANDIDATES  = { "fluid_interface", "me_dual_interface", "me_interface" }
-- 网卡候选（modem / tunnel）
local NET_CANDIDATES = { "modem", "tunnel" }

local cache          = {} -- kind -> { address = , compType = }，或 false = 查过、没有

--- 取某类组件的第一个（返回**地址**，调用走 device.invoke）
-- 【负缓存】没插卡/没接 ME 时把"没有"也记下来：界面每 0.25 秒问一次网卡在不在，
--   每次都真去 `component.list` 扫一遍组件表是白花时间（OC 每次要重建一张组件快照）。
--   插卡后要能认出来 —— T1 每 10 秒 `device.invalidate()` 一次，负缓存随之作废。
-- @param kind string 缓存键
-- @param candidates table 组件类型候选数组
-- @return string|nil 地址
-- @return string|nil 命中的组件类型
local function find(kind, candidates)
    local hit = cache[kind]
    if hit == false then return nil, nil end
    if hit and hit.address then return hit.address, hit.compType end

    for _, compType in ipairs(candidates) do
        local address = component.list(compType)() -- 迭代器调一次 = 取第一个
        if address then
            cache[kind] = { address = address, compType = compType }
            return address, compType
        end
    end
    cache[kind] = false
    return nil, nil
end

--- ME 网络接口的地址（读流体用）
-- @return string|nil 地址
-- @return string|nil 组件类型
function device.me() return find("me", ME_CANDIDATES) end

--- 网卡 / 隧道的地址（无线通信用）
-- @return string|nil 地址
-- @return string|nil 组件类型
function device.net() return find("net", NET_CANDIDATES) end

--- 清掉组件缓存（硬件重扫时调用）
function device.invalidate()
    cache = {}
end

--- 枚举全部 gt_machine 的**地址**
-- 只给地址：调用一律走 `device.invoke`（见下），proxy 对部分方法不可用，不留着让人误用。
-- @return table 地址数组 { "xxxx-...", ... }
function device.machines()
    local out = {}
    for address in component.list("gt_machine") do
        out[#out + 1] = address
    end
    return out
end

--- 机器名（`getName()`；取不到返回 nil）
-- @param address string 组件地址
-- @return string|nil
function device.name(address)
    if not address then return nil end
    local name = device.invoke(address, "getName")
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

--- 调用组件方法：**全工程统一走 component.invoke**
-- 实测：`getName` / `getEUCapacity` 可以用 proxy 索引调用，但
--   `isWorkAllowed` / `isMachineActive` / `getWorkProgress` / `getSensorInformation`
--   用 `proxy[method]()` 拿到的是 nil（不是 function），读数会静默变成"关 / 0"。
--   所以组件调用只保留这一个出口。
-- @param address string 组件地址
-- @param method string 方法名
-- @param ... any 参数
-- @return any|nil 返回值
-- @return string|nil 错误文本（成功时为 nil）
function device.invoke(address, method, ...)
    if not address then return nil, "地址为空" end
    local ok, value = pcall(component.invoke, address, method, ...)
    if not ok then return nil, tostring(value) end
    return value, nil
end

return device
