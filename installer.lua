--------------------------------------------------------------------------------
-- installer.lua   —— 净化水线安装器（OpenComputers）
-- 【别直接改这个文件】它是 `build_deploy.py` 从工作区根的 `publish_installer.lua` 生成的
--   （下面的 FILE_LIST 由脚本填），下次 build 会覆盖这里 —— 要改请改模板。
--------------------------------------------------------------------------------
-- 【做什么】把整个应用从 GitHub 拉下来（含各层子目录），装到 <当前目录>/PurifyWater
-- 【不做什么】不碰 <应用目录>/data/（那是程序自己记的阈值/实测/曲线/痕迹）；不删任何旧文件
-- 【怎么用】在 OC 电脑上（要装因特网卡 Internet Card）：
--     wget https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/installer.lua installer.lua
--     lua installer.lua            -- 普通安装（不写任何日志文件）
--     lua installer.lua --debug    -- 排错用：完整过程写进 <当前目录>/installer.log
-- 【为何不叫 install.lua】OpenOS 自带 `/bin/install.lua`（装 OpenOS 用的），名字撞上会很乱。
-- 【清单从哪来】下面的 FILE_LIST 由工作区的 `build_deploy.py` 生成（与应用目录里的文件逐一对应），
--   所以加了模块只要重新打包 + 重新 push，这份清单不会和仓库脱节 —— 不要手改。
-- 【下不下来怎么办】两层保险：① 直连 raw.githubusercontent.com 失败 → **整体**切备用镜像
--   （镜像前缀 + 原链接，见 MIRROR_PREFIX）；② 一轮跑完还有失败项 → 再整轮重试，
--   **每轮只给每个文件一次机会**（不在同一个文件上死磕），默认 3 轮。
-- 【留档只在 --debug 下】加了 `--debug`，每次尝试（轮次 / 通道 / 网址 / 结果）才攒下来，
--   跑完或失败时一次性写进 <当前目录>/installer.log —— OC 屏幕上滚掉的东西都能回去看。
--   不加就是普通安装：不攒、不写盘，**一个多余文件都不产生**。
--------------------------------------------------------------------------------

local component     = require("component")
local filesystem    = require("filesystem")
local shell         = require("shell")

-- ============================ 配置（只改这一块） ============================
-- 拉哪一份变体：
--   "build"       = 去注释版（**日常跑这个**，体积小一半）
--   "PurifyWater" = 带注释源码（要现场改代码才用）
local SRC           = "build"

local REPO_URL      = "https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/"
local BASE_URL      = REPO_URL .. SRC .. "/"

-- 备用通道：直连不通时，把原链接整个套在镜像域名后面（示例）
--   https://github.xutongxin.me/https://raw.githubusercontent.com/<...>/main/build/main.lua
-- 置 "" 就是只用直连。**一旦切到备用，后面的文件与重试都跟着走备用**（不逐文件混着用）。
local MIRROR_PREFIX = "https://github.xutongxin.me/"

-- 重试：整个清单跑一遍后还有失败项，就再来几轮（每轮每个文件只试一次，轮间才重试）
--   某一轮一个都没成功 = 这条通道也不通 → 下一轮换另一条再试
local RETRY_ROUNDS  = 3

-- 装到"当前工作目录/PurifyWater"（绝对路径，避免歧义）
local APP_DIR       = (shell.getWorkingDirectory() .. "/PurifyWater"):gsub("//+", "/")
-- 过程日志（跑完/失败时一次性写盘；屏幕滚掉的东西都在里面）
local LOG_PATH      = (shell.getWorkingDirectory() .. "/installer.log"):gsub("//+", "/")
-- 过程日志：默认**不开**（不加 --debug 时连文件都不写）；要开就是命令行加 --debug / -d
local LOG_ON        = false
-- 文件清单：应用目录下的相对路径（= 仓库里 SRC 目录下的相对路径），子目录会自动建
local FILE_LIST     = {
    "main.lua",
    "monitor.lua",
    "backend/api.lua",
    "backend/app/plan.lua",
    "backend/app/system.lua",
    "backend/app/watch.lua",
    "backend/debug/memwatch.lua",
    "backend/domain/actuator.lua",
    "backend/domain/allocator.lua",
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
    "backend/store/records.lua",
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
-- ==========================================================================

-- `--debug` / `-d`：把过程日志打开（OC 里就是 `lua installer.lua --debug`）
for _, a in ipairs({ ... }) do
    if a == "--debug" or a == "-d" then LOG_ON = true end
end

--- 递归建目录（OC 的 makeDirectory 不会替你建父目录）
-- @param dir string 绝对路径
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

--- 拼下载地址：ch = 1 直连、2 备用（备用 = 镜像前缀 + 原链接）
-- @param ch number
-- @param rel string 应用目录下的相对路径
-- @return string
local function urlFor(ch, rel)
    local direct = BASE_URL .. rel
    if ch == 2 and MIRROR_PREFIX ~= "" then return MIRROR_PREFIX .. direct end
    return direct
end

local CH_NAME = { "直连", "备用" }

-- 过程日志：只在 --debug 下攒（不开就只有一个空表，不占内存、不写盘）
local LOG_LINES = {}
local function log(text)
    if LOG_ON then LOG_LINES[#LOG_LINES + 1] = text end
end

--- 把过程日志写盘（成功、失败两条路各调一次；**没开日志就什么都不做**）
-- @param title string 第一行：这次的结果
local function flushLog(title)
    if not LOG_ON then return end
    local f = io.open(LOG_PATH, "w")
    if not f then
        print("[提示] 日志没写成：" .. LOG_PATH)
        return
    end
    f:write(title .. "\n" .. table.concat(LOG_LINES, "\n") .. "\n")
    f:close()
    print("过程日志：" .. LOG_PATH)
end

--- 用系统 wget 下一个文件
-- 【-f】= 强制覆盖：OpenOS 的 wget 默认**拒绝**覆盖已存在的文件，而重装时目标一定在那儿。
--   （不另外再 remove 一遍 —— 同一件事做两遍；只留 `-f` 这一处。）
--   **不要加引号**：OC 的 shell 按空格切参数 —— 路径里不能有空格，见 main() 开头那道检查。
-- 【判定只认"存在且非空"】曾经在这里加过 `loadfile` 编译校验（想挡半截文件 / 错误页），
--   实机翻车：文件明明下齐了，它却对一批文件一律报错，把整套安装误判成失败。
--   所以判定放宽，编译的情况**只记进日志**，不影响成败。
-- @param url string
-- @param dest string
-- @return boolean 是否成功
-- @return number|string 成功时是字节数，失败时是说明
local function fetch(url, dest)
    local rc = shell.execute("wget -f " .. url .. " " .. dest) -- 阻塞，直到下完
    if not filesystem.exists(dest) or filesystem.size(dest) == 0 then
        return false, "没下到内容（wget 返回 " .. tostring(rc) .. "：404 / 超时 / 网络不通）"
    end
    local okLoad, chunk, lerr = pcall(loadfile, dest)
    if not okLoad or not chunk then
        log("      [诊断] loadfile 没通过（不判失败，仅留档）："
            .. tostring(not okLoad and chunk or lerr))
    end
    return true, filesystem.size(dest)
end

--- 写一个启动器：从任何目录都能跑，也方便写进 /autorun.lua
-- @return boolean
-- @return string|nil 失败原因
local function writeLauncher()
    local f, err = filesystem.open(APP_DIR .. "/start.lua", "wb")
    if not f then return false, err end
    f:write(([[
-- start.lua（安装器生成）：把应用目录塞进 require 搜索路径后跑 main.lua
local appDir = "%s"
package.path = appDir .. "/?.lua;" .. appDir .. "/?/init.lua;" .. package.path
local fn, e = loadfile(appDir .. "/main.lua")
if not fn then error(e) end
fn()
]]):format(APP_DIR))
    f:close()
    return true
end

local function main()
    if APP_DIR:find(" ") then
        error("当前目录里有空格（" .. APP_DIR .. "）：OC 的 wget 命令行按空格切参数，请换个目录再装。")
    end
    if not component.isAvailable("internet") then
        error("没检测到因特网卡（Internet Card）：安装要从 GitHub 下载文件。")
    end

    print("== 净化水线 安装器 ==")
    print("变体： " .. SRC .. (SRC == "build" and "（去注释版）" or ""))
    print("源：   " .. BASE_URL)
    print("备用： " .. (MIRROR_PREFIX ~= "" and (MIRROR_PREFIX .. "（直连失败时整体切过去）") or "无（只走直连）"))
    print("目标： " .. APP_DIR)
    if filesystem.exists(APP_DIR) then
        print("       目录已存在：只覆盖清单里的同名文件 —— 上游删掉/改名的旧文件不会被清掉，")
        print("       要干净就先把 " .. APP_DIR .. " 删掉（data/ 里有你的阈值与实测记录，先备份）。")
    end
    print("文件： " .. #FILE_LIST .. "（失败会整轮重试，最多 " .. RETRY_ROUNDS .. " 轮）")
    print()

    ensureDir(APP_DIR) -- 先建应用目录本身（清单里第一个文件就在它下面）

    -- 待下清单：每轮只给每个文件一次机会，成功的从里面拿掉
    local pending = {}
    for i, rel in ipairs(FILE_LIST) do pending[i] = rel end

    local reasons   = {} -- 每个失败文件的最后一次原因（汇总时打在文件后面）
    local ch, round = 1, 0
    local total     = #FILE_LIST

    log("变体 " .. SRC .. "，源 " .. BASE_URL .. "，备用 " .. MIRROR_PREFIX)

    while true do
        print(string.format("── 第 %d 轮：%s 通道，待下 %d 个%s",
            round + 1, CH_NAME[ch], #pending,
            round > 0 and string.format("（重试 %d/%d）", round, RETRY_ROUNDS) or ""))

        local failed, okRound = {}, 0
        for i, rel in ipairs(pending) do
            local dir = rel:match("^(.*)/[^/]*$")
            if dir then ensureDir(APP_DIR .. "/" .. dir) end

            local url      = urlFor(ch, rel)
            local ok, info = fetch(url, APP_DIR .. "/" .. rel)
            io.write(string.format("  [%2d/%2d] %-34s ", i, #pending, rel))
            if ok then
                print("OK  (" .. info .. " 字节)")
                okRound = okRound + 1
            else
                print("失败（" .. tostring(info) .. "）")
                failed[#failed + 1] = rel
                reasons[rel] = tostring(info)
            end
            log(string.format("第 %d 轮 %s [%d/%d] %-34s %s  %s", round + 1, CH_NAME[ch], i, #pending,
                rel, ok and ("OK " .. tostring(info) .. " 字节") or ("失败：" .. tostring(info)), url))

            -- 【一次失败就整体切备用】不逐文件混着用通道：本轮余下的与之后的重试都走备用
            if not ok and ch == 1 and MIRROR_PREFIX ~= "" then
                ch = 2
                log("  → 直连失败，改用备用通道：" .. MIRROR_PREFIX)
                print("         直连失败 → 余下文件改用备用通道：" .. MIRROR_PREFIX)
            end
        end

        -- 【顺序要紧】先把本轮失败项收成新的待下清单，再判"是不是全好了" ——
        --   反过来写（先 break）会把上一轮的整份清单留在 pending 里，全成功也会被判成"全没下来"。
        pending = failed
        if #pending == 0 then break end
        if round >= RETRY_ROUNDS then break end

        round = round + 1
        -- 【整轮一个都没成】说明这条通道也不通 → 下一轮换另一条（每轮只用一条通道）
        if okRound == 0 and MIRROR_PREFIX ~= "" then ch = (ch == 1) and 2 or 1 end
        print()
    end

    print()
    if #pending > 0 then
        local title = string.format("安装失败：成功 %d/%d，重试 %d 轮后仍有 %d 个没下来",
            total - #pending, total, round, #pending)
        print(title .. "：")
        for _, rel in ipairs(pending) do
            print("  - " .. rel .. "（" .. tostring(reasons[rel] or "?") .. "）")
        end
        flushLog(title)
        if not LOG_ON then
            print("（想看完整过程：加 --debug 重跑一次 —— lua installer.lua --debug，会写 " .. LOG_PATH .. "）")
        end
        error("安装没完成：先把失败的补上再跑（应用目录里现在是半套代码，别直接启动）。")
    end

    local okL, errL = writeLauncher()
    if not okL then
        print("[提示] start.lua 没写成：" .. tostring(errL) .. "（不影响使用，按下面的命令启动）")
    end

    print("完成：全部 " .. total .. " 个文件到位"
        .. (round > 0 and ("（重试 " .. round .. " 轮，末轮通道 " .. CH_NAME[ch] .. "）") or ""))
    flushLog(string.format("安装完成：全部 %d 个文件到位（用了 %d 轮，末轮通道 %s）",
        total, round + 1, CH_NAME[ch]))
    print()
    print("启动： cd " .. APP_DIR .. " && lua main.lua")
    print("      " .. APP_DIR .. "/start          （等价写法，从任何目录都能跑）")
    print("调试： lua " .. APP_DIR .. "/main.lua --debug")
    print("镜像： lua " .. APP_DIR .. "/monitor.lua [端口]     （另一台电脑 + 无线网卡）")
    print("自启： 把 " .. APP_DIR .. "/start 写进 /autorun.lua")
    print()
    print("更新： 重跑本安装器即可（只覆盖清单里的文件，data/ 与阈值记录都不动）")
end

local ok, err = xpcall(main, debug.traceback) -- 不要 pcall 吞错
if not ok then print("\n[安装出错]\n" .. tostring(err)) end
