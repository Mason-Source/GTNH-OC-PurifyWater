--------------------------------------------------------------------------------
-- installer.lua   —— 净化水线安装器（OpenComputers）
-- 【别直接改这个文件】它是 `build_deploy.py` 从工作区根的 `publish_installer.lua` 生成的
--   （下面的 FILE_LIST 由脚本填），下次 build 会覆盖这里 —— 要改请改模板。
--------------------------------------------------------------------------------
-- 【做什么】把整个应用从 GitHub 拉下来（含各层子目录），装到 <当前目录>/PurifyWater
-- 【不做什么】不碰 <应用目录>/data/（那是程序自己记的阈值/实测/曲线/痕迹）；不删任何旧文件
-- 【怎么用】在 OC 电脑上（要装因特网卡 Internet Card）：
--     wget https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/installer.lua installer.lua
--     lua installer.lua
-- 【为何不叫 install.lua】OpenOS 自带 `/bin/install.lua`（装 OpenOS 用的），名字撞上会很乱。
-- 【清单从哪来】下面的 FILE_LIST 由工作区的 `build_deploy.py` 生成（与应用目录里的文件逐一对应），
--   所以加了模块只要重新打包 + 重新 push，这份清单不会和仓库脱节 —— 不要手改。
-- 【下不下来怎么办】两层保险：① 直连 raw.githubusercontent.com 失败 → **整体**切备用镜像
--   （镜像前缀 + 原链接，见 MIRROR_PREFIX）；② 一轮跑完还有失败项 → 再整轮重试，
--   **每轮只给每个文件一次机会**（不在同一个文件上死磕），默认 3 轮。
--------------------------------------------------------------------------------

local component  = require("component")
local filesystem = require("filesystem")
local shell      = require("shell")

-- ============================ 配置（只改这一块） ============================
-- 拉哪一份变体：
--   "build"       = 去注释版（**日常跑这个**，体积小一半）
--   "PurifyWater" = 带注释源码（要现场改代码才用）
local SRC        = "build"

local REPO_URL   = "https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/"
local BASE_URL   = REPO_URL .. SRC .. "/"

-- 备用通道：直连不通时，把原链接整个套在镜像域名后面（示例）
--   https://github.xutongxin.me/https://raw.githubusercontent.com/<...>/main/build/main.lua
-- 置 "" 就是只用直连。**一旦切到备用，后面的文件与重试都跟着走备用**（不逐文件混着用）。
local MIRROR_PREFIX = "https://github.xutongxin.me/"

-- 重试：整个清单跑一遍后还有失败项，就再来几轮（每轮每个文件只试一次，轮间才重试）
--   某一轮一个都没成功 = 这条通道也不通 → 下一轮换另一条再试
local RETRY_ROUNDS  = 3

-- 装到"当前工作目录/PurifyWater"（绝对路径，避免歧义）
local APP_DIR    = (shell.getWorkingDirectory() .. "/PurifyWater"):gsub("//+", "/")

-- 文件清单：应用目录下的相对路径（= 仓库里 SRC 目录下的相对路径），子目录会自动建
local FILE_LIST  = {
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

--- 用系统 wget 下一个文件，并验一次"能不能编译"
-- 【wget -f】-f = 强制覆盖已存在的文件（OpenOS 的 wget 默认会拒绝），所以不用先删。
-- 【不要加引号】OC 的 shell 按空格切参数 —— 路径里不能有空格，见 main() 开头那道检查。
-- 【为何下完还要 loadfile】超时中断会留下半截文件（存在且非空），只看大小会当成成功；
--   镜像站出毛病时还可能回个 200 + 一页 HTML。真编译一次，两种都能当场发现 → 交给重试。
-- @param url string
-- @param dest string
-- @return boolean 是否成功
-- @return number|string 成功时是字节数，失败时是说明
local function fetch(url, dest)
    local rc = shell.execute("wget -f " .. url .. " " .. dest) -- 阻塞，直到下完
    if not filesystem.exists(dest) or filesystem.size(dest) == 0 then
        return false, "没下到内容（wget 返回 " .. tostring(rc) .. "：404 / 超时 / 网络不通）"
    end
    local chunk, err = loadfile(dest)
    if not chunk then
        return false, "下到的不是可用的 Lua（可能被截断或是个错误页）：" .. tostring(err)
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

    local ch, round = 1, 0
    local total     = #FILE_LIST

    while true do
        print(string.format("── 第 %d 轮：%s 通道，待下 %d 个%s",
            round + 1, CH_NAME[ch], #pending,
            round > 0 and string.format("（重试 %d/%d）", round, RETRY_ROUNDS) or ""))

        local failed, okRound = {}, 0
        for i, rel in ipairs(pending) do
            local dir = rel:match("^(.*)/[^/]*$")
            if dir then ensureDir(APP_DIR .. "/" .. dir) end

            io.write(string.format("  [%2d/%2d] %-34s ", i, #pending, rel))
            local ok, info = fetch(urlFor(ch, rel), APP_DIR .. "/" .. rel)
            if ok then
                print("OK  (" .. info .. " 字节)")
                okRound = okRound + 1
            else
                print("失败（" .. tostring(info) .. "）")
                failed[#failed + 1] = rel
                -- 【一次失败就整体切备用】不逐文件混着用通道：本轮余下的与之后的重试都走备用
                if ch == 1 and MIRROR_PREFIX ~= "" then
                    ch = 2
                    print("         直连失败 → 余下文件改用备用通道：" .. MIRROR_PREFIX)
                end
            end
        end

        if #failed == 0 then break end
        pending = failed
        if round >= RETRY_ROUNDS then break end

        round = round + 1
        -- 【整轮一个都没成】说明这条通道也不通 → 下一轮换另一条（每轮只用一条通道）
        if okRound == 0 and MIRROR_PREFIX ~= "" then ch = (ch == 1) and 2 or 1 end
        print()
    end

    print()
    if #pending > 0 then
        print(string.format("完成：成功 %d/%d，重试 %d 轮后仍有 %d 个没下来：",
            total - #pending, total, round, #pending))
        for _, rel in ipairs(pending) do print("  - " .. rel) end
        error("安装没完成：先把失败的补上再跑（应用目录里现在是半套代码，别直接启动）。")
    end

    local okL, errL = writeLauncher()
    if not okL then
        print("[提示] start.lua 没写成：" .. tostring(errL) .. "（不影响使用，按下面的命令启动）")
    end

    print("完成：全部 " .. total .. " 个文件到位"
        .. (round > 0 and ("（重试 " .. round .. " 轮，末轮通道 " .. CH_NAME[ch] .. "）") or ""))
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
