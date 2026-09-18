--------------------------------------------------------------------------------
-- backend/store/inventory.lua
--------------------------------------------------------------------------------
-- 【职责】硬件拓扑清单（`data/hardware.txt`）：**有变化才写**，
--         并与上一次比对出 { changed, added, removed } 供 T1 发 hardware_changed
-- 【不做什么】不扫描组件（那是 hardware/machines）
-- 【依赖】store/files、shared/config
-- 【被谁用】backend/jobs（T1）
--
-- 这张清单用于发现"换了能源仓 / 加了单元"（会让并行记录的功率快照失效），
--   清单变化就是重学（重测并行）的触发条件之一。
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local files     = require("backend.store.files")

local inventory = {}

--- 一行的格式：`level address name`
-- @param item table { level, address, name }
-- @return string
local function toLine(item)
    return string.format("%s %s %s", tostring(item.level), tostring(item.address), tostring(item.name))
end

--- 从一行里取地址（用作比对键）
-- @param line string
-- @return string|nil
local function addressOf(line)
    return tostring(line):match("^%S+%s+(%S+)")
end

--- 与盘上清单比对；有变化（或首次运行）才写盘
-- @param items table machines.topology() 的结果
-- @return table { changed = boolean, added = {name...}, removed = {line...}, path = string }
function inventory.compareAndSave(items)
    local path = files.path(CONFIG.FILES.HARDWARE)
    local prev = files.readLines(path)

    local prevSet = {}
    for _, line in ipairs(prev) do
        local address = addressOf(line)
        if address then prevSet[address] = line end
    end

    local lines, nowSet = {}, {}
    for _, item in ipairs(items or {}) do
        lines[#lines + 1] = toLine(item)
        nowSet[item.address] = item
    end
    table.sort(lines)

    local added, removed = {}, {}
    for address, item in pairs(nowSet) do
        if not prevSet[address] then added[#added + 1] = item.name end
    end
    for address, line in pairs(prevSet) do
        if not nowSet[address] then removed[#removed + 1] = line end
    end
    table.sort(added)
    table.sort(removed)

    local changed = #added > 0 or #removed > 0
    -- 首次运行（盘上没有清单）也写一份，但**不算变化**（避免启动时白报一次"硬件变更"）
    if changed or #prev == 0 then files.writeLines(path, lines) end

    return { changed = changed, added = added, removed = removed, path = path }
end

return inventory
