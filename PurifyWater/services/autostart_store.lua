-- 开机自启块的文件读写与解析：$HOME/.shrc 标记块。
-- 全工程唯一接触 .shrc 的模块；真源 = 标记块是否存在且指向当前 main.lua。
local storage = require("services.storage")

local store = {}

local BEGIN_MARK = "# >>> PurifyWater autostart >>>"
local END_MARK = "# <<< PurifyWater autostart <<<"

local function shrcPath()
    local home = os.getenv("HOME")
    if type(home) ~= "string" or home == "" then home = "/home" end
    return home .. "/.shrc"
end

local function appPath()
    return tostring(storage.root() or "."):gsub("[/\\]+$", "")
end

local function mainPath()
    return appPath() .. "/main.lua"
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitLines(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line:gsub("\r$", "")
    end
    if out[#out] == "" then out[#out] = nil end
    return out
end

local function joinLines(lines)
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
end

local function extractBlocks(lines)
    local kept, commands, removed = {}, {}, 0
    local index = 1
    while index <= #lines do
        if trim(lines[index]) == BEGIN_MARK then
            removed = removed + 1
            index = index + 1
            while index <= #lines and trim(lines[index]) ~= END_MARK do
                local body = trim(lines[index])
                if body ~= "" then commands[#commands + 1] = body end
                index = index + 1
            end
            if index <= #lines then index = index + 1 end
        else
            kept[#kept + 1] = lines[index]
            index = index + 1
        end
    end
    return kept, commands, removed
end

local function findManualLine(lines, target)
    for _, line in ipairs(lines) do
        local value = trim(line)
        if value ~= "" and value:sub(1, 1) ~= "#" and value:find(target, 1, true) then
            return value
        end
    end
    return nil
end

function store.read()
    local path = shrcPath()
    local text = storage.readText(path)
    local kept, commands = extractBlocks(splitLines(text))
    local target = commands[#commands] or nil
    local want = mainPath()
    local matches = target ~= nil and target:find(want, 1, true) ~= nil

    return {
        enabled = matches,
        stale = target ~= nil and not matches,
        path = path,
        target = target,
        exists = text ~= nil,
        manualLine = findManualLine(kept, want),
    }
end

function store.enable()
    local path = shrcPath()
    local kept = extractBlocks(splitLines(storage.readText(path)))
    kept[#kept + 1] = BEGIN_MARK
    kept[#kept + 1] = string.format('cd "%s"', appPath())
    kept[#kept + 1] = string.format('lua "%s"', mainPath())
    kept[#kept + 1] = END_MARK

    local ok, err = storage.writeText(path, joinLines(kept))
    if not ok then return false, tostring(err or "写文件失败") end
    return true, path
end

function store.disable()
    local path = shrcPath()
    if not storage.exists(path) then return true, path end

    local kept, _, removed = extractBlocks(splitLines(storage.readText(path)))
    if removed == 0 then return true, path end

    local ok, err = storage.writeText(path, joinLines(kept))
    if not ok then return false, tostring(err or "写文件失败") end
    return true, path
end

function store.path() return shrcPath() end
function store.target() return mainPath() end

return store
