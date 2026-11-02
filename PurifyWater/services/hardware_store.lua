--------------------------------------------------------------------------------
-- PurifyWater/services/hardware_store.lua
--
-- 定位：data/hardware.txt 的持久化适配器。
-- 功能：当拓扑文本变化时保存设备登记行，并为扫描服务提供读回接口。
-- 边界：不解释设备条目，不触发扫描。
--------------------------------------------------------------------------------

local storage = require("services.storage")

local hardware_store = {}
local PATH = "data/hardware.txt"

--- 读取 data/hardware.txt 的登记行。
function hardware_store.loadLines()
    return storage.readLines(PATH)
end

--- 仅在拓扑文本变化时写回 data/hardware.txt。
function hardware_store.saveLines(lines)
    local current = storage.readLines(PATH)
    if table.concat(current, "\n") == table.concat(lines, "\n") then
        return true, false
    end
    local ok, err = storage.replace(PATH, lines)
    if not ok then return false, err end
    return true, true
end

--- 返回硬件登记文件路径。
function hardware_store.path()
    return PATH
end

return hardware_store
