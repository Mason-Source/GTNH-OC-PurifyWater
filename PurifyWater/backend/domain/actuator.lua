--------------------------------------------------------------------------------
-- backend/domain/actuator.lua
--------------------------------------------------------------------------------
-- 【职责】全工程**唯一**改机器开关的地方：算好的方案 -> setWorkAllowed
-- 【依赖】backend/hardware/{device,machines}、shared/{state,constants}
-- 【被谁用】backend/app/plan（正常调度）、backend/app/system（停机 / 急停）
--
-- 【下发与回读分在两个周期】本文件**只发不读**：
--     * 本周期：setWorkAllowed + 登记 state.cmd[level]（"我们发了什么"的凭据）
--     * 下一周期：T3 读到开关 -> app/watch 拿 cmd 对比 -> 不符才报警（归因表见 ARCHITECTURE §4.4）
--   同一个周期里刚下发就回读，机器可能还没走完自己的 tick，读回的是旧值，只会造出假告警。
-- 【回执】只回答"命令发出去没有"（调用是否报错），没有"回读值"这东西。
-- 【归因】下发时登记 state.cmd[level] = { want, at }：
--         下一周期观测到开关与意图不符，就能判断"是我们刚下发的、还是别人（玩家）改的"
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
            -- 归因凭据：这套意图是我们刚发的（下一周期读到时比对一次就清掉，见 app/watch）
            state.cmd[level] = { want = want, at = now }
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
