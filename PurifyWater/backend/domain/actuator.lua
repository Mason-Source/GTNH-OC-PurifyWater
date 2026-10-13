--------------------------------------------------------------------------------
-- backend/domain/actuator.lua
--------------------------------------------------------------------------------
-- 【职责】唯一改机器开关的地方：方案 -> setWorkAllowed
-- 【依赖】backend/hardware/{device,machines}、shared/constants
-- 【被谁用】backend/app/plan（正常调度）、backend/app/system（停机 / 急停）
--
-- 只发不读：setWorkAllowed 立即生效，下一读数即反映下发；判定在 app/watch。
-- 回执只有"是否发出"（调用报错），无回读值。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local computer  = require("computer")
local device    = require("backend.hardware.device")
local machines  = require("backend.hardware.machines")

local actuator  = {}

local receipt   = { at = 0, items = {} }

--- 应用一套方案（plan[level] = true/false）
-- @param plan table
-- @return number count 本套方案涉及多少台机器
-- @return table failed { [level] = 错误文本 }（下发报错的等级）
function actuator.apply(plan)
    local now    = computer.uptime()
    receipt      = { at = now, items = {} }

    local count  = 0
    local failed = {}
    for level = 1, constants.LEVEL_COUNT do
        local list = machines.of(level)
        if #list > 0 then
            local want = plan[level] == true
            for _, m in ipairs(list) do
                local item = { level = level, address = m.address, want = want, ok = true }
                -- 只发不读，回读对比留到下周期
                local _, err = device.invoke(m.address, "setWorkAllowed", want)
                if err then
                    item.ok, item.err = false, err
                    failed[level]     = tostring(err)
                end
                receipt.items[#receipt.items + 1] = item
                count = count + 1
            end
        end
    end
    return count, failed
end

--- 全部关闭（停机 / 急停）
-- @return number 涉及台数
function actuator.shutdownAll()
    return actuator.apply({})
end

--- 最近一次下发的回执（只有发出与否，无回读值）
-- @return table { at, items }
function actuator.lastReceipt()
    return receipt
end

--- 回执 -> 一行说明（日志/界面用）
-- @return string
function actuator.describeReceipt()
    local failed = 0
    for _, item in ipairs(receipt.items) do
        if not item.ok then failed = failed + 1 end
    end
    return string.format("下发 %d 台，失败 %d 台", #receipt.items, failed)
end

return actuator
