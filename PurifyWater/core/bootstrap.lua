--------------------------------------------------------------------------------
-- core/bootstrap.lua
--------------------------------------------------------------------------------
-- 【职责】启动前的"卫生工作"：清旧模块缓存、解析命令行参数、版本戳；退出前把屏幕交还 shell
-- 【不做什么】不注册任务、不建事件循环、不碰硬件、不调垃圾回收（OC 里没得调，见下）
-- 【依赖】shared/{logs,constants}
-- 【被谁用】main.lua / monitor.lua
--------------------------------------------------------------------------------

local logs         = require("shared.logs")
local constants    = require("shared.constants")

local bootstrap    = {}

-- 本工程自己的模块前缀（清理缓存时只看这些，别把 OC 官方模块清掉）
local OWN_PREFIXES = { "core.", "shared.", "backend", "frontend" }

--- 清掉本工程模块的 require 缓存
-- OpenOS 的 shell 把 require 过的模块留在 package.loaded 里：换完文件后只重跑程序
-- 不一定拿到新代码（实测：文件是新的、跑的还是旧逻辑）。
-- @param prefixes string[]|nil 自定义前缀；默认本工程前缀
-- @return integer 清掉的模块数
function bootstrap.clearModuleCache(prefixes)
    prefixes = prefixes or OWN_PREFIXES
    local removed = 0
    for name in pairs(package.loaded) do
        for _, prefix in ipairs(prefixes) do
            if name == prefix or name:sub(1, #prefix) == prefix then
                package.loaded[name] = nil
                removed = removed + 1
                break
            end
        end
    end
    return removed
end

--- 解析命令行参数（目前只有日志级别，见 logs.applyArgs）
-- @param args table 参数数组
function bootstrap.applyArgs(args)
    logs.applyArgs(args or {})
end

--- 退出前把屏幕交还 shell：整屏刷黑（黑底白字）+ 光标回左上
-- 【为什么要刷】界面是**直接画在 gpu 上**的，不走 shell 的终端缓冲区 —— shell 不知道屏幕被占过，
--   退出后它只在"自己写过的那几行"上重画，于是那几行退出信息正好压在界面残影上（实机现象：
--   退出信息挤在前几行，字被残影盖着看不清）。刷一次就不必去猜"残影有几行、屏幕现在几行"。
-- 【为何不用 term.clear】它按终端**缓存的**宽高清屏，而分辨率刚被还原过（`screen_resized`
--   还没被主循环取走）—— 缓存可能是旧的，边角会留一条残影。这里直接问 gpu 要当前分辨率。
-- 【为何安全】此刻界面已收工（`render.restoreResolution` 已跑过），屏上没有别人在用；
--   两段都包 pcall：没有 term / 没有 gpu 也只是刷不了屏，不该影响退出。
function bootstrap.releaseConsole()
    local okComp, component = pcall(require, "component")
    if okComp and type(component) == "table" and component.gpu then
        local gpu = component.gpu
        pcall(gpu.setBackground, 0x000000) -- 黑底
        pcall(gpu.setForeground, 0xFFFFFF) -- 白字（界面的配色还留在 gpu 上）
        local w, h = gpu.getResolution()
        pcall(gpu.fill, 1, 1, w, h, " ")
    end

    -- 光标回左上：退出信息从第一行开始写（上面只刷了画面，终端自己的光标还在原处）
    local okTerm, term = pcall(require, "term")
    if okTerm and type(term) == "table" and type(term.setCursor) == "function" then
        pcall(term.setCursor, 1, 1)
    end
end

-- 【没有"垃圾回收调参"这一步】OC 的沙箱里 `collectgarbage` 是 nil（实机报
--   `attempt to call a nil value (global 'collectgarbage')`），回收参数根本改不了。
--   能做的只有两件：少造垃圾（界面/视图层）、少留数据（内存只留屏幕上放得下的），
--   剩下的靠主循环每帧 `event.pull` 让出时 GC 自己跑。

--- 内核版本戳（不带"内核版本"字样）：`v4.0`；跑 `--debug` 时带 `-debug` 后缀
-- 【为什么要后缀】屏幕日志与 `last_run.txt` 都写它 —— 一眼看出这轮跑的是正式版还是调试版。
-- 【为什么在这里拼】后缀取决于日志级别，而 `constants` 是无依赖的常量表（不能去 require logs）。
-- @return string
function bootstrap.version()
    return constants.CODE_VERSION .. (logs.isDebug() and "-debug" or "")
end

--- 版本戳文本（启动日志第一行；**不带前缀**，前缀由 logs.system 统一加）
-- @return string
function bootstrap.versionLine()
    return "内核版本 " .. bootstrap.version()
end

return bootstrap
