--------------------------------------------------------------------------------
-- backend/domain/actuator.lua
--------------------------------------------------------------------------------
-- 【职责】全工程**唯一**改机器开关的地方：算好的方案 -> setWorkAllowed
-- 【依赖】backend/hardware/{device,machines}、shared/{state,constants}
-- 【被谁用】backend/app/plan（正常调度）、backend/app/system（停机 / 急停）
--
-- 【下发与回读分在两个周期】本文件**只发不读**：
--   本周期 setWorkAllowed + 登记一条**待确认的下发记录** `state.cmd[level] = { want }`；
--   之后 T3 读到开关时把记录随事实带上、由 app/watch 认领 —— 相符即销账，不符即报警
--   （归因表见 ARCHITECTURE §4.4）。同一个周期里刚下发就回读，机器可能还没走完自己的 tick，
--   读回的是旧值，只会造出假告警。
-- 【回执】只回答"命令发出去没有"（调用是否报错），没有"回读值"这东西。
-- 【凭据 = 身份，不是时刻】每次下发**换一张新表**：表引用本身就是"哪一次下发"的身份。
--   比时刻不可靠：`computer.uptime()` 是**游戏刻 ÷ 20**（0.05 秒分辨率），而主循环一帧可能跨
--   好几个游戏刻，判定时取到的时刻必然晚于本帧下发 -> 下发前读的旧值会被当成新命令的回音。
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
            -- 凭据：这套意图是我们刚发的（T3 读数时带上、相符即销账，见 app/watch 的归因）
            state.cmd[level] = { want = want }
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
