--------------------------------------------------------------------------------
-- core/bootstrap.lua
--------------------------------------------------------------------------------
-- 【职责】启动前清旧模块缓存、解析参数、拼版本戳；退出前交还屏幕
-- 【不做什么】不注册任务、不建事件循环、不碰硬件
-- 【依赖】shared/{logs,constants}
-- 【被谁用】main.lua / monitor.lua
--------------------------------------------------------------------------------

local logs         = require("shared.logs")
local constants    = require("shared.constants")

local bootstrap    = {}

-- 本工程模块前缀（清缓存只看这些）
local OWN_PREFIXES = { "core.", "shared.", "backend", "frontend" }

--- 清掉本工程模块的 require 缓存
-- OpenOS 会把已加载模块留在 package.loaded；换文件后重跑可能仍是旧代码，先清。
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

--- 退出前把屏幕交还 shell：整屏刷黑 + 光标回左上
-- 界面直接画在 gpu，shell 不知道屏幕被占过，退出信息会压在残影上，先清一次。
-- 不用 term.clear：分辨率刚还原，其缓存尺寸是旧的；两段都 pcall，失败不影响退出。
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

-- OC 无 collectgarbage；内存控制靠少造垃圾、少留数据。

--- 内核版本戳：vX.Y；--debug 加 -debug 后缀。
-- 后缀依赖日志级别，故在此拼（constants 不能 require logs）。
-- @return string
function bootstrap.version()
    return constants.CODE_VERSION .. (logs.isDebug() and "-debug" or "")
end

--- 启动日志第一行（前缀由 logs 统一加）
-- @return string
function bootstrap.versionLine()
    return "内核版本 " .. bootstrap.version()
end

return bootstrap
