-- 主题注册表：界面只认语义色，不直接持有色值。
local CONFIG = require("shared.config")

local dark = require("frontend.theme.dark")
local light = require("frontend.theme.light")

local themes = {
    dark = dark,
    light = light,
}
local order = CONFIG.UI.THEMES or { "dark", "light" }
local currentId = CONFIG.UI.DEFAULT_THEME or "dark"

local registry = {}

function registry.has(id)
    return themes[id] ~= nil
end

function registry.get(id)
    return themes[id] or themes[currentId]
end

function registry.list()
    local out = {}
    for _, id in ipairs(order) do
        if themes[id] then out[#out + 1] = themes[id] end
    end
    return out
end

function registry.current()
    return themes[currentId]
end

function registry.currentId()
    return currentId
end

function registry.set(id)
    if themes[id] then currentId = id end
    return themes[currentId]
end

function registry.cycle()
    local nextId = currentId
    for index, id in ipairs(order) do
        if id == currentId then
            nextId = order[index % #order + 1]
            break
        end
    end
    currentId = nextId
    return themes[currentId]
end

return registry
