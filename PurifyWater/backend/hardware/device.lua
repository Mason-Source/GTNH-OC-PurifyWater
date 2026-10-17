--------------------------------------------------------------------------------
-- backend/hardware/device.lua
--------------------------------------------------------------------------------
-- 【职责】按名字找组件并缓存：ME 接口、网卡/隧道；枚举 gt_machine 与转运器
-- 【不做什么】不读业务状态量（probes/energy/fluid）、不判业务
-- 【依赖】component
-- 【被谁用】hardware/{machines,energy,fluid,net}、backend/jobs(T1)
--
-- 每周期一次 sweep() 全量枚举组件，再分别 scanMe() / scanNet() / scanMachines()
-- 更新各自缓存；其余模块只读缓存。
--------------------------------------------------------------------------------

local component      = require("component")

local device         = {}

-- ME 网络接口的候选组件名（按序查找）
local ME_CANDIDATES  = { "fluid_interface", "me_interface" }
-- 网卡候选（modem / tunnel）
local NET_CANDIDATES = { "modem", "tunnel" }

local cache          = { me = false, net = false } -- false = 查过、没有
local sweepList      = {}                          -- 上次 sweep 的全量结果 {address, ctype}
local machineAddrs   = {}                          -- gt_machine 地址表


local function inCandidates(ctype, list)
    for _, candidate in ipairs(list) do
        if ctype == candidate then return true end
    end
    return false
end

--- 全量枚举组件一次，结果存 sweepList；由 T1 每周期调用
function device.sweep()
    local out = {}
    for address, ctype in component.list() do
        out[#out + 1] = { address = address, ctype = ctype }
    end
    sweepList = out
end

--- 从 sweepList 里找 ME 接口并写缓存
function device.scanMe()
    for _, item in ipairs(sweepList) do
        if inCandidates(item.ctype, ME_CANDIDATES) then
            cache["me"] = { address = item.address, compType = item.ctype }
            return
        end
    end
    cache["me"] = false
end

--- 从 sweepList 里找网卡/隧道并写缓存
function device.scanNet()
    for _, item in ipairs(sweepList) do
        if inCandidates(item.ctype, NET_CANDIDATES) then
            cache["net"] = { address = item.address, compType = item.ctype }
            return
        end
    end
    cache["net"] = false
end

--- 从 sweepList 里收集全部 gt_machine 地址
-- @return table 地址数组
function device.scanMachines()
    local out = {}
    for _, item in ipairs(sweepList) do
        if item.ctype == "gt_machine" then out[#out + 1] = item.address end
    end
    machineAddrs = out
    return out
end

--- ME 网络接口的地址（读流体用）
-- @return string|nil 地址
-- @return string|nil 组件类型
function device.me()
    local hit = cache["me"]
    if hit then return hit.address, hit.compType end
    return nil, nil
end

--- 网卡/隧道的地址（无线通信用）
-- @return string|nil 地址
-- @return string|nil 组件类型
function device.net()
    local hit = cache["net"]
    if hit then return hit.address, hit.compType end
    return nil, nil
end

--- 上次 scanMachines() 收集的 gt_machine 地址
-- @return table 地址数组
function device.machines()
    return machineAddrs
end

--- 即时枚举全部转运器地址（只有"点[绑定]"与"绑定中"才调用；平时的在线检查见 isTransposerOnline）
-- @return table 地址数组
function device.scanTransposers()
    local out = {}
    for address in component.list("transposer") do out[#out + 1] = address end
    return out
end

--- 某个地址现在是否还是"在网且类型为 transposer"的组件（单点探测，不枚举全部转运器）
-- 只用于"已绑定件还在不在"的在线检查（T1 每轮，10 秒一次）。
-- @param address string|nil
-- @return boolean
function device.isTransposerOnline(address)
    if not address or address == "" then return false end
    local ok, ctype = pcall(component.type, address)
    return ok and ctype == "transposer"
end

--- 机器名（getName()；取不到返回 nil）
-- @param address string 组件地址
-- @return string|nil
function device.name(address)
    if not address then return nil end
    local name = device.invoke(address, "getName")
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

--- 机器坐标（gt_machine.getCoordinates；选项关闭 / 不可用时返回 nil）
-- device.invoke 只带三个返回值，getCoordinates 是多返回值，故这里直接 pcall。
-- @param address string 组件地址
-- @return number|nil x
-- @return number|nil y
-- @return number|nil z
function device.coordinates(address)
    if not address then return nil, nil, nil end
    local ok, x, y, z = pcall(component.invoke, address, "getCoordinates")
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return x, y, z
    end
    return nil, nil, nil
end

--- 调用组件方法：全工程统一出口。
-- 部分方法经 proxy 索引拿到的是 nil，读数会静默成关/0，故只留 component.invoke。
-- @param address string 组件地址
-- @param method string 方法名
-- @param ... any 参数
-- @return any|nil 返回值
-- @return string|nil 错误文本（成功时为 nil）
-- @return any|nil 第二个返回值（如广播失败时的 "not enough energy"）
function device.invoke(address, method, ...)
    if not address then return nil, "地址为空" end
    local ok, value, reason = pcall(component.invoke, address, method, ...)
    if not ok then return nil, tostring(value) end
    return value, nil, reason
end

return device
