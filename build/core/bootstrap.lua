local logs         = require("shared.logs")
local constants    = require("shared.constants")
local bootstrap    = {}
local OWN_PREFIXES = { "core.", "shared.", "backend", "frontend" }
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
function bootstrap.applyArgs(args)
    logs.applyArgs(args or {})
end
function bootstrap.releaseConsole()
    local okComp, component = pcall(require, "component")
    if okComp and type(component) == "table" and component.gpu then
        local gpu = component.gpu
        pcall(gpu.setBackground, 0x000000)
        pcall(gpu.setForeground, 0xFFFFFF)
        local w, h = gpu.getResolution()
        pcall(gpu.fill, 1, 1, w, h, " ")
    end
    local okTerm, term = pcall(require, "term")
    if okTerm and type(term) == "table" and type(term.setCursor) == "function" then
        pcall(term.setCursor, 1, 1)
    end
end
function bootstrap.version()
    return constants.CODE_VERSION .. (logs.isDebug() and "-debug" or "")
end
function bootstrap.versionLine()
    return "内核版本 " .. bootstrap.version()
end
return bootstrap
