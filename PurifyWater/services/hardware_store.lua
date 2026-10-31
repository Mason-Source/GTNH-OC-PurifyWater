-- data/hardware.txt：设备登记持久化；按设备规范文本比较，有变化才写。
local storage = require("services.storage")

local hardware_store = {}
local PATH = "data/hardware.txt"

function hardware_store.loadLines()
    return storage.readLines(PATH)
end

function hardware_store.saveLines(lines)
    local current = storage.readLines(PATH)
    if table.concat(current, "\n") == table.concat(lines, "\n") then
        return true, false
    end
    local ok, err = storage.replace(PATH, lines)
    if not ok then return false, err end
    return true, true
end

function hardware_store.path()
    return PATH
end

return hardware_store
