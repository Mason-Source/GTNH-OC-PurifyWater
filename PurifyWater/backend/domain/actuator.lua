--------------------------------------------------------------------------------
-- backend/domain/actuator.lua
--------------------------------------------------------------------------------
-- 【职责】全工程**唯一**改机器开关的地方：算好的方案 -> setWorkAllowed
-- 【依赖】backend/hardware/{device,machines}、shared/{state,constants}
-- 【被谁用】backend/app/plan（正常调度）、backend/app/system（停机 / 急停）
--
-- 【只发不读】本文件不读回开关、也不记"我发过什么"：`setWorkAllowed` 立即写进机器的 `mWorks`、
--   `isWorkAllowed` 立即读得到，所以"下一条读数"必然反映我们的下发，不需要任何凭据。
--   判定在 app/watch：**实测 ≠ 方案就是人动过机器** -> 停机 + 锁定（见 ARCHITECTURE §4.4）。
-- 【回执】只回答"命令发出去没有"（调用是否报错），没有"回读值"这东西；
--   `receipt.at` 只用于告警行的"最近一次下发几秒前"。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")
local computer  = require("computer")
local device    = require("backend.hardware.device")
local machines  = require("backend.hardware.machines")

local actuator  = {}

local receipt   = { at = 0, items = {} }

--- 应用一套方案（plan[level] = true/false）
-- @param plan table
-- @return number count 本套方案涉及多少台机器
-- @return table failed { [level] = 错误文本 } —— **下发报错**的等级（调用方要据此别把意图当真）
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
                -- 只发不读：回读对比留给下一个调度周期（见文件头）
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

--- 最近一次下发的回执（**只有"发了什么 / 发失败没有"**，没有回读值）
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
