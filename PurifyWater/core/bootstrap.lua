-- 启动清理：清掉本工程模块缓存，确保重跑加载新文件。
local constants = require("shared.constants")

local bootstrap = {}

local OWN_PREFIXES = {
    "core.", "shared.", "services.", "business.", "hardware.",
    "frontend.", "kernel", "main", "monitor"
}

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

function bootstrap.version()
    return constants.CODE_VERSION
end

return bootstrap
