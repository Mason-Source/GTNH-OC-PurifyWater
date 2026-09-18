--------------------------------------------------------------------------------
-- install.lua   —— 净化水线安装器（OpenComputers）
--------------------------------------------------------------------------------
-- 【做什么】把整个应用从 GitHub 拉下来（含各层子目录），装到 <当前目录>/PurifyWater
-- 【不做什么】不碰 <应用目录>/data/（那是程序自己记的阈值/实测/曲线/痕迹）；不删任何旧文件
-- 【怎么用】在 OC 电脑上（要装因特网卡 Internet Card）：
--     wget https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/install.lua install.lua
--     lua install.lua
-- 【清单从哪来】下面的 FILE_LIST 由工作区的 `build_deploy.py` 生成（与应用目录里的文件逐一对应），
--   所以加了模块只要重新打包 + 重新 push，这份清单不会和仓库脱节 —— 不要手改。
--------------------------------------------------------------------------------

local component  = require("component")
local filesystem = require("filesystem")
local shell      = require("shell")

-- ============================ 配置（只改这一块） ============================
-- 拉哪一份变体：
--   "build"       = 去注释版（**日常跑这个**，体积小一半）
--   "PurifyWater" = 带注释源码（要现场改代码才用）
local SRC      = "build"

local REPO_URL = "https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/"
local BASE_URL = REPO_URL .. SRC .. "/"

-- 装到"当前工作目录/PurifyWater"（绝对路径，避免歧义）
local APP_DIR  = (shell.getWorkingDirectory() .. "/PurifyWater"):gsub("//+", "/")

-- 文件清单：应用目录下的相对路径（= 仓库里 SRC 目录下的相对路径），子目录会自动建
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

--- 用系统 wget 下一个文件
-- 【先删再下】wget 默认拒绝覆盖已存在的文件；【不要加引号】OC 的 shell 按空格切参数，
-- 所以路径里不能有空格 —— 见 main() 开头那道检查。
-- @param url string
-- @param dest string
-- @return boolean 是否成功
-- @return number|string 成功时是字节数，失败时是说明
local function wget(url, dest)
    if filesystem.exists(dest) then filesystem.remove(dest) end
    local rc = shell.execute("wget " .. url .. " " .. dest) -- 阻塞，直到下完
    if filesystem.exists(dest) and filesystem.size(dest) > 0 then
        return true, filesystem.size(dest)
    end
    return false, "wget 返回 " .. tostring(rc) .. "（多半是 404：确认该文件已 push 到 " .. SRC .. "/ 下）"
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
    print("目标： " .. APP_DIR)
    if filesystem.exists(APP_DIR) then
        print("       目录已存在：只覆盖清单里的同名文件 —— 上游删掉/改名的旧文件不会被清掉，")
        print("       要干净就先把 " .. APP_DIR .. " 删掉（data/ 里有你的阈值与实测记录，先备份）。")
    end
    print("文件： " .. #FILE_LIST)
    print()

    ensureDir(APP_DIR) -- 先建应用目录本身（清单里第一个文件就在它下面）

    local okCount, fail = 0, {}
    for i, rel in ipairs(FILE_LIST) do
        local dir = rel:match("^(.*)/[^/]*$")
        if dir then ensureDir(APP_DIR .. "/" .. dir) end

        io.write(string.format("[%2d/%2d] %-34s ", i, #FILE_LIST, rel))
        local ok, info = wget(BASE_URL .. rel, APP_DIR .. "/" .. rel)
        if ok then
            print("OK  (" .. info .. " 字节)")
            okCount = okCount + 1
        else
            print("失败")
            fail[#fail + 1] = rel .. " -> " .. tostring(info)
        end
    end

    print()
    if #fail > 0 then
        print("完成：成功 " .. okCount .. "/" .. #FILE_LIST .. "，以下失败：")
        for _, m in ipairs(fail) do print("  - " .. m) end
        error("安装没完成：先把失败的补上再跑（应用目录里现在是半套代码，别直接启动）。")
    end

    local okL, errL = writeLauncher()
    if not okL then
        print("[提示] start.lua 没写成：" .. tostring(errL) .. "（不影响使用，按下面的命令启动）")
    end

    print("完成：成功 " .. okCount .. "/" .. #FILE_LIST .. " 个文件")
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
