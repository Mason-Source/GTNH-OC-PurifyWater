--------------------------------------------------------------------------------
-- PurifyWater/core/bootstrap.lua
--
-- 定位：运行时引导与进程级辅助功能。
-- 功能：清理工程模块缓存、读取统一版本号，并在退出后恢复终端光标与背景。
-- 边界：不承载业务状态，不读取或下发设备数据。
--------------------------------------------------------------------------------

local constants = require("shared.constants")

local bootstrap = {}

local OWN_PREFIXES = {
    "core.", "shared.", "services.", "business.", "hardware.",
    "frontend.", "kernel", "main", "monitor"
}

--- 清除本工程已加载模块，使重复运行能够载入最新文件。
function bootstrap.clearModuleCache(prefixes)
    local removed = 0
    for name in pairs(package.loaded) do
        for _, prefix in ipairs(prefixes or OWN_PREFIXES) do
            if name == prefix or name:sub(1, #prefix) == prefix then
                package.loaded[name] = nil
                removed = removed + 1
                break
            end
        end
    end
    return removed
end

--- 清屏并把终端光标恢复到指定行。
function bootstrap.releaseConsole(startRow)
    local okComponent, component = pcall(require, "component")
    if okComponent and type(component) == "table" and component.gpu then
        local gpu = component.gpu
        pcall(gpu.setBackground, 0x000000)
        pcall(gpu.setForeground, 0xFFFFFF)
        local width, height = gpu.getResolution()
        pcall(gpu.fill, 1, 1, width, height, " ")
    end

    local okTerm, term = pcall(require, "term")
    if okTerm and type(term) == "table" and type(term.setCursor) == "function" then
        pcall(term.setCursor, 1, math.max(1, tonumber(startRow) or 1))
    end
end

--- 返回 shared/constants.lua 中维护的唯一代码版本号。
function bootstrap.version()
    return constants.CODE_VERSION
end

return bootstrap
