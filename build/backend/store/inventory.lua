local CONFIG    = require("shared.config")
local files     = require("backend.store.files")
local inventory = {}
local function toLine(item)
    return string.format("%s %s %s", tostring(item.level), tostring(item.address), tostring(item.name))
end
local function addressOf(line)
    return tostring(line):match("^%S+%s+(%S+)")
end
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
    if changed or #prev == 0 then files.writeLines(path, lines) end
    return { changed = changed, added = added, removed = removed, path = path }
end
return inventory
