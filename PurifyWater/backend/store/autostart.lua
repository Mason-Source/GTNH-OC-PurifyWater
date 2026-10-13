--------------------------------------------------------------------------------
-- backend/store/autostart.lua
--------------------------------------------------------------------------------
-- 【职责】开机自启块的文件读写与解析：$HOME/.shrc 标记块
-- 【不做什么】不写日志、不改 state、不认识界面（那些在 backend/app/autostart）
-- 【依赖】backend/store/files（唯一写盘原语）
-- 【被谁用】backend/app/autostart.lua
--
-- .shrc 逐行当 shell 命令执行：块内是 # 注释行 + lua 命令，属本程序的唯一部分。
-- 勾选 = 改写/追加，取消 = 整段删除，其余内容不动。
-- 真源 = 块在不在且是否指向当前应用目录；指向别处只报 stale。
--------------------------------------------------------------------------------

local files = require("backend.store.files")

local autostart = {}

local BEGIN_MARK = "# >>> PurifyWater autostart >>>"
local END_MARK   = "# <<< PurifyWater autostart <<<"

--- .shrc 路径（HOME 取不到按 /home）
-- @return string
local function shrcPath()
    local home = os.getenv("HOME")
    if type(home) ~= "string" or home == "" then home = "/home" end
    return home .. "/.shrc"
end

--- main.lua 绝对路径
-- @return string
local function mainPath()
    return files.root() .. "/main.lua"
end

--- 去首尾空白
-- @param text string|nil
-- @return string
local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 文本 -> 行数组（丢 CR）
-- @param text string|nil
-- @return table
local function splitLines(text)
    local out = {}
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line:gsub("\r$", "")
    end
    if out[#out] == "" then out[#out] = nil end
    return out
end

--- 行数组 -> 文本（LF，末尾补换行）
-- @param lines table
-- @return string
local function joinLines(lines)
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
end

--- 摘出自启块；缺结束标记的残块按到文件尾处理。
-- @param lines table
-- @return table, table, number
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
            if i <= #lines then i = i + 1 end -- 跳过结束标记
        else
            kept[#kept + 1] = lines[i]
            i = i + 1
        end
    end
    return kept, commands, removed
end

--- 块外手动启动行（只提醒）
-- @param lines table
-- @param target string 本程序 main.lua 的绝对路径
-- @return string|nil 命中的那一行
local function findManualLine(lines, target)
    for _, line in ipairs(lines) do
        local text = trim(line)
        if text ~= "" and text:sub(1, 1) ~= "#" and text:find(target, 1, true) then
            return text
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- 对外
--------------------------------------------------------------------------------

--- 读当前状态（不写任何东西）
-- @return table { enabled, stale, path, target, exists, manualLine }
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

--- 勾选：删旧块后追加新块；其余保留
-- @return boolean ok
-- @return string 路径（成功）或失败原因
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

--- 取消勾选：删掉所有自启块；本来就没有块就一个字节都不动
-- @return boolean ok
-- @return string 路径（成功）或失败原因
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
