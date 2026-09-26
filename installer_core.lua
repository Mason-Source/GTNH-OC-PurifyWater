--------------------------------------------------------------------------------
-- installer_core.lua —— PurifyWater 实际安装器
--------------------------------------------------------------------------------
-- 【职责】下载应用代码到 staging，按 manifest 同步到 <当前目录>/PurifyWater。
-- 【不做什么】不碰 data/ 中的用户数据；不删除清单外文件。
-- 【参数】--mirror/-m 首选镜像；--debug/-d 写 installer.log；--source=build|PurifyWater。
--------------------------------------------------------------------------------

local component  = require("component")
local filesystem = require("filesystem")
local shell      = require("shell")

local ARGS       = { ... }
local SRC        = "build"
local PREFER     = 1
local LOG_ON     = false

for _, a in ipairs(ARGS) do
    if a == "--debug" or a == "-d" then LOG_ON = true end
    if a == "--mirror" or a == "-m" then PREFER = 2 end
    if a == "--source=PurifyWater" or a == "--src=PurifyWater" then SRC = "PurifyWater" end
    if a == "--source=build" or a == "--src=build" then SRC = "build" end
end

local REPO_URL      = "https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/"
local BASE_URL      = REPO_URL .. SRC .. "/"
local MIRROR_PREFIX = "https://github.xutongxin.me/"
local RETRY_ROUNDS  = 3

local CWD           = shell.getWorkingDirectory():gsub("//+", "/")
local APP_DIR       = (CWD .. "/PurifyWater"):gsub("//+", "/")
local STAGE_DIR     = (CWD .. "/.PurifyWater.update"):gsub("//+", "/")
local BACKUP_DIR    = (CWD .. "/.PurifyWater.backup"):gsub("//+", "/")
local LOG_PATH      = (CWD .. "/installer.log"):gsub("//+", "/")
local MANIFEST_REL  = "data/install_manifest.txt"

-- 首次从旧安装器迁移时，需要明确清理的旧文件。以后依赖 manifest 自动计算。
local RETIRED_FILES = {
    "backend/store/records.lua",
}

local FILE_LIST = {
    "main.lua",
    "monitor.lua",
    "backend/api.lua",
    "backend/app/plan.lua",
    "backend/app/system.lua",
    "backend/app/watch.lua",
    "backend/debug/memwatch.lua",
    "backend/domain/actuator.lua",
    "backend/domain/allocator.lua",
    "backend/domain/learning.lua",
    "backend/domain/power.lua",
    "backend/domain/rules.lua",
    "backend/domain/tracker.lua",
    "backend/handlers.lua",
    "backend/hardware/device.lua",
    "backend/hardware/energy.lua",
    "backend/hardware/fluid.lua",
    "backend/hardware/gt_infodata.lua",
    "backend/hardware/machines.lua",
    "backend/hardware/net.lua",
    "backend/hardware/probes.lua",
    "backend/jobs.lua",
    "backend/store/files.lua",
    "backend/store/history.lua",
    "backend/store/inventory.lua",
    "backend/store/levels_config.lua",
    "backend/store/log_file.lua",
    "backend/store/settings.lua",
    "backend/store/trace.lua",
    "core/bootstrap.lua",
    "core/locate.lua",
    "core/runtime.lua",
    "core/scheduler.lua",
    "frontend/charts.lua",
    "frontend/input.lua",
    "frontend/layout.lua",
    "frontend/panels/chart.lua",
    "frontend/panels/config.lua",
    "frontend/panels/control.lua",
    "frontend/panels/detail.lua",
    "frontend/panels/editline.lua",
    "frontend/panels/keypad.lua",
    "frontend/panels/log.lua",
    "frontend/panels/status.lua",
    "frontend/panels/tabbar.lua",
    "frontend/render.lua",
    "frontend/state.lua",
    "frontend/theme.lua",
    "frontend/viewmodel.lua",
    "frontend/widgets.lua",
    "shared/config.lua",
    "shared/constants.lua",
    "shared/logs.lua",
    "shared/models.lua",
    "shared/state.lua",
    "shared/utils.lua",
}

local CH_NAME = { "直连", "备用" }
local LOG_LINES = {}

local function log(text)
    if LOG_ON then LOG_LINES[#LOG_LINES + 1] = text end
end

local function flushLog(title)
    if not LOG_ON then return end
    local f = io.open(LOG_PATH, "w")
    if not f then return end
    f:write(title .. "\n" .. table.concat(LOG_LINES, "\n") .. "\n")
    f:close()
    print("过程日志：" .. LOG_PATH)
end

local function ensureDir(dir)
    if filesystem.exists(dir) then return true end
    local parent = dir:match("^(.*)/[^/]*$")
    if parent and parent ~= "" and parent ~= dir then ensureDir(parent) end
    local ok, err = filesystem.makeDirectory(dir)
    if not ok and not filesystem.exists(dir) then
        error("无法创建目录 " .. dir .. "：" .. tostring(err))
    end
    return true
end

local function removeTree(path)
    if not filesystem.exists(path) then return end
    local ok, iter = pcall(filesystem.list, path)
    if ok and iter then
        local names = {}
        for name in iter do names[#names + 1] = name end
        for _, name in ipairs(names) do
            if name ~= "." and name ~= ".." then removeTree(path .. "/" .. name) end
        end
    end
    filesystem.remove(path)
end

local function safeRel(rel)
    return type(rel) == "string" and rel ~= "" and rel:sub(1, 1) ~= "/"
        and not rel:find("(^|/)%.%.(/|$)")
end

local function readManifest()
    local set, count = {}, 0
    if not filesystem.exists(APP_DIR .. "/" .. MANIFEST_REL) then return set end
    local f = io.open(APP_DIR .. "/" .. MANIFEST_REL, "r")
    if not f then return set end
    local text = f:read("*a") or ""
    f:close()
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and safeRel(line) then
            set[line] = true
            count = count + 1
        end
    end
    return set, count
end

local function writeManifest(root, list)
    ensureDir(root .. "/data")
    local f, err = io.open(root .. "/" .. MANIFEST_REL, "w")
    if not f then return false, err end
    f:write("# PurifyWater install manifest v1\n")
    for _, rel in ipairs(list) do f:write(rel .. "\n") end
    f:close()
    return true
end

local function urlFor(ch, rel)
    local direct = BASE_URL .. rel
    if ch == 2 and MIRROR_PREFIX ~= "" then return MIRROR_PREFIX .. direct end
    return direct
end

local function fetch(url, dest)
    local tmp = dest .. ".tmp"
    filesystem.remove(tmp)
    local rc = shell.execute("wget -f " .. url .. " " .. tmp)
    if not filesystem.exists(tmp) or filesystem.size(tmp) == 0 then
        filesystem.remove(tmp)
        return false, "没下到内容（wget 返回 " .. tostring(rc) .. "）"
    end
    local okLoad, chunk, lerr = pcall(loadfile, tmp)
    if not okLoad or not chunk then
        log("      [诊断] loadfile 未通过（不判失败）：" .. tostring(not okLoad and chunk or lerr))
    end
    local size = filesystem.size(tmp)
    filesystem.remove(dest)
    local _, mvErr = filesystem.rename(tmp, dest)
    if filesystem.exists(tmp) then
        filesystem.remove(tmp)
        return false, "改名失败：" .. tostring(mvErr)
    end
    return true, size
end

local function writeLauncher(root)
    local f, err = io.open(root .. "/start.lua", "w")
    if not f then return false, err end
    f:write(([[
local appDir = "%s"
package.path = appDir .. "/?.lua;" .. appDir .. "/?/init.lua;" .. package.path
local fn, e = loadfile(appDir .. "/main.lua")
if not fn then error(e) end
fn()
]]):format(APP_DIR))
    f:close()
    return true
end

local function downloadAll()
    removeTree(STAGE_DIR)
    ensureDir(STAGE_DIR)

    local pending = {}
    for i, rel in ipairs(FILE_LIST) do pending[i] = rel end
    local reasons, ch, round = {}, PREFER, 0

    while true do
        print(string.format("── 第 %d 轮：%s 通道，待下 %d 个", round + 1, CH_NAME[ch], #pending))
        local failed, okRound = {}, 0
        for i, rel in ipairs(pending) do
            local dir = rel:match("^(.*)/[^/]*$")
            if dir then ensureDir(STAGE_DIR .. "/" .. dir) end
            local url = urlFor(ch, rel)
            local ok, info = fetch(url, STAGE_DIR .. "/" .. rel)
            if ok then
                okRound = okRound + 1
                print(string.format("  [%2d/%2d] %-36s OK (%s 字节)", i, #pending, rel, info))
            else
                failed[#failed + 1] = rel
                reasons[rel] = tostring(info)
                print(string.format("  [%2d/%2d] %-36s 失败（%s）", i, #pending, rel, info))
            end
            log(string.format("第 %d 轮 %s %s -> %s", round + 1, CH_NAME[ch], rel, ok and "OK" or info))
        end

        pending = failed
        if #pending == 0 then return true end
        if round >= RETRY_ROUNDS then break end
        round = round + 1
        if okRound == 0 and MIRROR_PREFIX ~= "" then ch = (ch == 1) and 2 or 1 end
    end

    local lines = { "下载失败：" }
    for _, rel in ipairs(pending) do lines[#lines + 1] = "  " .. rel .. "：" .. tostring(reasons[rel]) end
    error(table.concat(lines, "\n"))
end

local function moveTo(src, dst)
    local parent = dst:match("^(.*)/[^/]*$")
    if parent then ensureDir(parent) end
    if filesystem.exists(dst) then filesystem.remove(dst) end
    local ok, err = filesystem.rename(src, dst)
    if not ok or filesystem.exists(src) or not filesystem.exists(dst) then
        return false, err or "rename 后文件状态不正确"
    end
    return true
end

local function commit(oldManifest)
    local managed = {}
    local newSet  = {}
    for _, rel in ipairs(FILE_LIST) do managed[#managed + 1] = rel; newSet[rel] = true end
    managed[#managed + 1] = "start.lua"; newSet["start.lua"] = true
    managed[#managed + 1] = MANIFEST_REL; newSet[MANIFEST_REL] = true

    local stale = {}
    local staleSet = {}
    for rel in pairs(oldManifest or {}) do staleSet[rel] = true end
    for _, rel in ipairs(RETIRED_FILES) do staleSet[rel] = true end
    for rel in pairs(staleSet) do
        if not newSet[rel] and safeRel(rel) and rel:sub(1, 5) ~= "data/" and rel:sub(-4) == ".lua" then
            stale[#stale + 1] = rel
        end
    end

    removeTree(BACKUP_DIR)
    ensureDir(BACKUP_DIR)

    local backed, installed = {}, {}
    local function backup(rel)
        local target = APP_DIR .. "/" .. rel
        if not filesystem.exists(target) then return end
        local dest = BACKUP_DIR .. "/" .. rel
        local ok, err = moveTo(target, dest)
        if not ok then error("备份失败 " .. rel .. "：" .. tostring(err)) end
        backed[#backed + 1] = rel
    end

    local function rollback()
        for i = #installed, 1, -1 do removeTree(APP_DIR .. "/" .. installed[i]) end
        for i = #backed, 1, -1 do
            local rel = backed[i]
            moveTo(BACKUP_DIR .. "/" .. rel, APP_DIR .. "/" .. rel)
        end
        removeTree(STAGE_DIR)
        removeTree(BACKUP_DIR)
    end

    local ok, err = xpcall(function()
        for _, rel in ipairs(managed) do backup(rel) end
        for _, rel in ipairs(stale) do backup(rel) end
        for _, rel in ipairs(managed) do
            local src = STAGE_DIR .. "/" .. rel
            if not filesystem.exists(src) then error("staging 缺文件：" .. rel) end
            local moved, moveErr = moveTo(src, APP_DIR .. "/" .. rel)
            if not moved then error("安装失败 " .. rel .. "：" .. tostring(moveErr)) end
            installed[#installed + 1] = rel
        end
        return true
    end, debug.traceback)

    if not ok then
        rollback()
        error(err)
    end
    removeTree(STAGE_DIR)
    removeTree(BACKUP_DIR)
end

local function main()
    if CWD:find(" ") then
        error("当前目录里有空格（" .. CWD .. "）：OC 的 wget 命令行按空格切参数，请换目录。")
    end
    if not component.isAvailable("internet") then
        error("没检测到因特网卡（Internet Card）。")
    end
    if PREFER == 2 and MIRROR_PREFIX == "" then PREFER = 1 end

    print("== 净化水线 安装器核心 ==")
    print("变体：" .. SRC)
    print("目标：" .. APP_DIR)
    print("文件：" .. #FILE_LIST .. " 个")

    local oldManifest, oldCount = readManifest()
    downloadAll()

    local managed = {}
    for _, rel in ipairs(FILE_LIST) do managed[#managed + 1] = rel end
    managed[#managed + 1] = "start.lua"
    managed[#managed + 1] = MANIFEST_REL
    local okL, errL = writeLauncher(STAGE_DIR)
    if not okL then error("start.lua 生成失败：" .. tostring(errL)) end
    local okM, errM = writeManifest(STAGE_DIR, managed)
    if not okM then error("manifest 生成失败：" .. tostring(errM)) end

    print(string.format("同步：旧清单 %d 个，新清单 %d 个", oldCount or 0, #managed))
    commit(oldManifest)

    print("完成：全部 " .. #FILE_LIST .. " 个文件到位，data/ 未改动")
    flushLog(string.format("安装完成：代码 %d 个，旧清单 %d 个", #FILE_LIST, oldCount or 0))
    return true
end

local ok, result, err = xpcall(main, debug.traceback)
if not ok then
    print("\n[安装出错]\n" .. tostring(result))
    removeTree(STAGE_DIR)
    flushLog("安装失败：" .. tostring(result))
    return false, result
end
return result, err
