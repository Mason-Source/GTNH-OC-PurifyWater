--------------------------------------------------------------------------------
-- installer_core.lua —— PurifyWater 实际安装器（PW1 单载荷版）
--------------------------------------------------------------------------------
-- 【职责】下载一个角色载荷，分拆到 staging，再按 manifest 同步到 <当前目录>/PurifyWater。
-- 【不做什么】不碰 data/ 中的用户数据；不删除清单外文件；不使用数据卡/压缩。
-- 【载荷】build/payload_main.bundle / build/payload_monitor.bundle
-- 【参数】--monitor = 装镜像端；--mirror/-m = 首选备用通道；
--         --debug/-d = 写 installer.log。
--------------------------------------------------------------------------------

local component  = require("component")
local filesystem = require("filesystem")
local shell      = require("shell")

local ARGS       = { ... }
local PREFER     = 1
local ROLE       = "main"
local LOG_ON     = false

for _, a in ipairs(ARGS) do
    if a == "--debug" or a == "-d" then LOG_ON = true end
    if a == "--mirror" or a == "-m" then PREFER = 2 end
    if a == "--monitor" then ROLE = "monitor" end
end

local BUNDLE_VERSION = "v5.3.4"
local REPO_URL       = "https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/build/"
local MIRROR_PREFIX  = "https://github.xutongxin.me/"
local RETRY_ROUNDS   = 3

local CWD            = shell.getWorkingDirectory():gsub("//+", "/")
local APP_DIR        = (CWD .. "/PurifyWater"):gsub("//+", "/")
local STAGE_DIR      = (CWD .. "/.PurifyWater.update"):gsub("//+", "/")
local BACKUP_DIR     = (CWD .. "/.PurifyWater.backup"):gsub("//+", "/")
local PAYLOAD_PATH   = (CWD .. "/.PurifyWater.payload"):gsub("//+", "/")
local LOG_PATH       = (CWD .. "/installer.log"):gsub("//+", "/")
local MANIFEST_REL   = "data/install_manifest.txt"

-- 首次从旧安装器迁移时，需要明确清理的旧文件。以后依赖 manifest 自动计算。
local RETIRED_FILES = {
    "backend/store/records.lua",
    "start.lua",
}

-- 文件清单由 build_deploy.py 按依赖闭包生成。
local FILE_LIST_COMMON = {
    "core/bootstrap.lua",
    "core/locate.lua",
    "core/scheduler.lua",
    "frontend/charts.lua",
    "frontend/decorate.lua",
    "frontend/layout.lua",
    "frontend/panels/chart.lua",
    "frontend/panels/control.lua",
    "frontend/panels/detail.lua",
    "frontend/panels/log.lua",
    "frontend/panels/status.lua",
    "frontend/panels/tabbar.lua",
    "frontend/render.lua",
    "frontend/state.lua",
    "frontend/theme.lua",
    "frontend/viewinput.lua",
    "frontend/widgets.lua",
    "shared/config.lua",
    "shared/constants.lua",
    "shared/logs.lua",
    "shared/models.lua",
    "shared/resources.lua",
    "shared/utils.lua",
}

local FILE_LIST_MAIN = {
    "main.lua",
    "backend/api.lua",
    "backend/app/autostart.lua",
    "backend/app/energy.lua",
    "backend/app/net.lua",
    "backend/app/plan.lua",
    "backend/app/produce.lua",
    "backend/app/produce/binding.lua",
    "backend/app/produce/executor.lua",
    "backend/app/produce/jobs.lua",
    "backend/app/produce/patrol.lua",
    "backend/app/produce/readiness.lua",
    "backend/app/produce/sides.lua",
    "backend/app/produce/view.lua",
    "backend/app/produce_job.lua",
    "backend/app/produce_runtime.lua",
    "backend/app/rates.lua",
    "backend/app/system.lua",
    "backend/app/watch.lua",
    "backend/domain/actuator.lua",
    "backend/domain/allocator.lua",
    "backend/domain/host_cycle.lua",
    "backend/domain/learning.lua",
    "backend/domain/mode.lua",
    "backend/domain/modes/rate.lua",
    "backend/domain/modes/threshold.lua",
    "backend/domain/power.lua",
    "backend/domain/produce.lua",
    "backend/domain/produce/check.lua",
    "backend/domain/produce/interface.lua",
    "backend/domain/produce/reconcile.lua",
    "backend/domain/produce/t3.lua",
    "backend/domain/produce/t4.lua",
    "backend/domain/produce/t5.lua",
    "backend/domain/produce/t6.lua",
    "backend/domain/produce/t7.lua",
    "backend/domain/produce/t8.lua",
    "backend/domain/rates.lua",
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
    "backend/hardware/transposer.lua",
    "backend/jobs.lua",
    "backend/store/autostart.lua",
    "backend/store/files.lua",
    "backend/store/history.lua",
    "backend/store/inventory.lua",
    "backend/store/levels_config.lua",
    "backend/store/log_file.lua",
    "backend/store/produce.lua",
    "backend/store/produce/format.lua",
    "backend/store/produce_config.lua",
    "backend/store/rates_config.lua",
    "backend/store/settings.lua",
    "backend/store/trace.lua",
    "core/runtime.lua",
    "frontend/input.lua",
    "frontend/panels/config.lua",
    "frontend/panels/keypad.lua",
    "frontend/panels/settings.lua",
    "frontend/viewmodel.lua",
    "shared/state.lua",
}

local FILE_LIST_MONITOR = {
    "monitor.lua",
}

local FILE_LIST = {}
for _, rel in ipairs(FILE_LIST_COMMON) do FILE_LIST[#FILE_LIST + 1] = rel end
local extra = (ROLE == "monitor") and FILE_LIST_MONITOR or FILE_LIST_MAIN
for _, rel in ipairs(extra) do FILE_LIST[#FILE_LIST + 1] = rel end

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
    local set, count, meta = {}, 0, {}
    if not filesystem.exists(APP_DIR .. "/" .. MANIFEST_REL) then return set, count, meta end
    local f = io.open(APP_DIR .. "/" .. MANIFEST_REL, "r")
    if not f then return set, count, meta end
    local text = f:read("*a") or ""
    f:close()
    for line in text:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line:sub(1, 1) == "#" then
            local key, value = line:match("^#%s*([%w_]+)=([^%s]+)")
            if key then meta[key] = value end
        elseif line ~= "" and safeRel(line) then
            set[line] = true
            count = count + 1
        end
    end
    return set, count, meta
end

local function writeManifest(root, list)
    ensureDir(root .. "/data")
    local f, err = io.open(root .. "/" .. MANIFEST_REL, "w")
    if not f then return false, err end
    f:write("# PurifyWater install manifest v2\n")
    f:write("# bundle_version=" .. BUNDLE_VERSION .. "\n")
    f:write("# bundle_role=" .. ROLE .. "\n")
    for _, rel in ipairs(list) do f:write(rel .. "\n") end
    f:close()
    return true
end

local function installedCurrent(manifest, count, meta)
    if meta.bundle_version ~= BUNDLE_VERSION
        or meta.bundle_role ~= ROLE then
        return false
    end
    if count ~= #FILE_LIST then return false end
    for _, rel in ipairs(FILE_LIST) do
        if not manifest[rel] or not filesystem.exists(APP_DIR .. "/" .. rel) then
            return false
        end
    end
    return true
end

local function payloadName()
    return ((ROLE == "monitor") and "payload_monitor" or "payload_main") .. ".bundle"
end

local function urlFor(ch, rel)
    local direct = REPO_URL .. rel
    if ch == 2 and MIRROR_PREFIX ~= "" then return MIRROR_PREFIX .. direct end
    return direct
end

local function fetchPayload(url, dest)
    local tmp = dest .. ".download"
    filesystem.remove(tmp)
    filesystem.remove(dest)
    local rc = shell.execute("wget -f " .. url .. " " .. tmp)
    if not filesystem.exists(tmp) or filesystem.size(tmp) == 0 then
        filesystem.remove(tmp)
        return false, "没下到载荷（wget 返回 " .. tostring(rc) .. "）"
    end
    local size = filesystem.size(tmp)
    local _, mvErr = filesystem.rename(tmp, dest)
    if filesystem.exists(tmp) then
        filesystem.remove(tmp)
        return false, "载荷改名失败：" .. tostring(mvErr)
    end
    return true, size
end

local function readExact(f, size)
    local chunks, remaining = {}, size
    while remaining > 0 do
        local chunk = f:read(math.min(remaining, 4096))
        if not chunk or #chunk == 0 then return nil end
        chunks[#chunks + 1] = chunk
        remaining = remaining - #chunk
    end
    return table.concat(chunks)
end

local function extractPayload(path)
    local f, err = io.open(path, "rb")
    if not f then return false, "打不开载荷：" .. tostring(err) end

    removeTree(STAGE_DIR)
    ensureDir(STAGE_DIR)
    local expected = {}
    for _, rel in ipairs(FILE_LIST) do expected[rel] = true end

    local ok, reason = xpcall(function()
        local header = f:read("*l")
        if not header then error("载荷缺头部") end
        local magic, rest = header:match("^(%S+)%s+(.*)$")
        if magic ~= "PW1" then error("载荷 magic 不对") end
        local meta = {}
        for key, value in rest:gmatch("([%w_]+)=([^%s]+)") do meta[key] = value end
        if meta.role ~= ROLE then error("载荷角色不一致：" .. tostring(meta.role)) end
        if meta.version ~= BUNDLE_VERSION then
            error("载荷版本不一致：" .. tostring(meta.version) .. " / " .. BUNDLE_VERSION)
        end
        local count = tonumber(meta.count)
        if not count or count < 1 or count ~= #FILE_LIST then
            error("载荷文件数不一致：" .. tostring(meta.count) .. " / " .. #FILE_LIST)
        end

        local seen = {}
        for _ = 1, count do
            local rel = f:read("*l")
            if not rel or not safeRel(rel) then error("载荷路径非法：" .. tostring(rel)) end
            if seen[rel] then error("载荷路径重复：" .. rel) end
            if not expected[rel] then error("载荷含清单外文件：" .. rel) end
            local sizeLine = f:read("*l")
            local size = tonumber(sizeLine)
            if not size or size < 0 or size % 1 ~= 0 then
                error("载荷长度非法：" .. rel .. " / " .. tostring(sizeLine))
            end
            local content = readExact(f, size)
            if content == nil then error("载荷内容截断：" .. rel) end
            local sep = f:read(1)
            if sep ~= "\n" then error("载荷缺分隔换行：" .. rel) end

            local dir = rel:match("^(.*)/[^/]*$")
            if dir then ensureDir(STAGE_DIR .. "/" .. dir) end
            local out, openErr = io.open(STAGE_DIR .. "/" .. rel, "wb")
            if not out then error("无法写入 staging：" .. rel .. " / " .. tostring(openErr)) end
            out:write(content)
            out:close()
            seen[rel] = true
        end
        if f:read(1) ~= nil then error("载荷尾部有多余内容") end
        for rel in pairs(expected) do
            if not seen[rel] then error("载荷缺文件：" .. rel) end
        end
    end, debug.traceback)

    f:close()
    if not ok then
        removeTree(STAGE_DIR)
        return false, reason
    end
    return true
end

local function downloadPayload()
    local rel = payloadName()
    local tryOrder = (PREFER == 2) and { 2, 1 } or { 1, 2 }
    local last = "未知错误"

    if PREFER == 2 and MIRROR_PREFIX == "" then tryOrder = { 1 } end

    for round = 1, RETRY_ROUNDS do
        for _, ch in ipairs(tryOrder) do
            local url = urlFor(ch, rel)
            print(string.format("下载载荷：%s（%s，第 %d 轮）", rel, CH_NAME[ch], round))
            local ok, info = fetchPayload(url, PAYLOAD_PATH)
            if ok then
                print(string.format("  下载完成：%s 字节", tostring(info)))
                log(string.format("载荷 %s %s -> OK (%s 字节)", CH_NAME[ch], url, tostring(info)))
                local extracted, why = extractPayload(PAYLOAD_PATH)
                if extracted then
                    filesystem.remove(PAYLOAD_PATH)
                    return true
                end
                last = why
                print("  分拆失败：" .. tostring(why))
                log(string.format("载荷 %s 分拆失败：%s", CH_NAME[ch], tostring(why)))
            else
                last = info
                print("  下载失败：" .. tostring(info))
                log(string.format("载荷 %s -> %s", CH_NAME[ch], tostring(info)))
            end
        end
    end
    filesystem.remove(PAYLOAD_PATH)
    error("载荷下载失败：" .. tostring(last))
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
    local newSet = {}
    for _, rel in ipairs(FILE_LIST) do managed[#managed + 1] = rel; newSet[rel] = true end
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

    print("== 净化水线 安装器核心 ==")
    print("角色：" .. (ROLE == "monitor" and "镜像端" or "主控端"))
    print("版本：" .. BUNDLE_VERSION)
    print("目标：" .. APP_DIR)
    print("文件：" .. #FILE_LIST .. " 个")

    local oldManifest, oldCount, oldMeta = readManifest()
    if installedCurrent(oldManifest, oldCount, oldMeta) then
        print("当前版本与角色已安装，跳过载荷下载。")
        flushLog("安装跳过：已是 " .. BUNDLE_VERSION .. " / " .. ROLE)
        return true
    end

    downloadPayload()

    local managed = {}
    for _, rel in ipairs(FILE_LIST) do managed[#managed + 1] = rel end
    managed[#managed + 1] = MANIFEST_REL
    local okM, errM = writeManifest(STAGE_DIR, FILE_LIST)
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
    filesystem.remove(PAYLOAD_PATH)
    flushLog("安装失败：" .. tostring(result))
    return false, result
end
return result, err
