local files = require("backend.store.files")
local autostart = {}
local BEGIN_MARK = "# >>> PurifyWater autostart >>>"
local END_MARK   = "# <<< PurifyWater autostart <<<"
local function shrcPath()
    local home = os.getenv("HOME")
    if type(home) ~= "string" or home == "" then home = "/home" end
    return home .. "/.shrc"
end
local function mainPath()
    return files.root() .. "/main.lua"
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
    local i = 1
    while i <= #lines do
        if trim(lines[i]) == BEGIN_MARK then
            removed = removed + 1
            i = i + 1
            while i <= #lines and trim(lines[i]) ~= END_MARK do
                local body = trim(lines[i])
                if body ~= "" then commands[#commands + 1] = body end
                i = i + 1
            end
            if i <= #lines then i = i + 1 end
        else
            kept[#kept + 1] = lines[i]
            i = i + 1
        end
    end
    return kept, commands, removed
end
local function findManualLine(lines, target)
    for _, line in ipairs(lines) do
        local text = trim(line)
        if text ~= "" and text:sub(1, 1) ~= "#" and text:find(target, 1, true) then
            return text
        end
    end
    return nil
end
function autostart.read()
    local path       = shrcPath()
    local text       = files.read(path)
    local kept, cmds = extractBlocks(splitLines(text))
    local target     = cmds[#cmds] or nil
    local want       = mainPath()
    local matches    = (target ~= nil) and (target:find(want, 1, true) ~= nil)
    return {
        enabled    = matches,
        stale      = (target ~= nil) and not matches,
        path       = path,
        target     = target,
        exists     = text ~= nil,
        manualLine = findManualLine(kept, want)
    }
end
function autostart.enable()
    local path      = shrcPath()
    local kept      = extractBlocks(splitLines(files.read(path)))
    kept[#kept + 1] = BEGIN_MARK
    kept[#kept + 1] = string.format('lua "%s"', mainPath())
    kept[#kept + 1] = END_MARK
    local ok, err = files.write(path, joinLines(kept))
    if not ok then return false, tostring(err or "写文件失败") end
    return true, path
end
function autostart.disable()
    local path       = shrcPath()
    if not files.exists(path) then return true, path end
    local kept, _, n = extractBlocks(splitLines(files.read(path)))
    if n == 0 then return true, path end
    local ok, err = files.write(path, joinLines(kept))
    if not ok then return false, tostring(err or "写文件失败") end
    return true, path
end
return autostart
