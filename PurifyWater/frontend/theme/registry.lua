--------------------------------------------------------------------------------
-- PurifyWater/frontend/theme/registry.lua
--
-- 定位：主题注册与当前主题管理。
-- 功能：按配置顺序列出主题，解析主题 ID，并维护当前主题。
-- 边界：只管理主题对象，不持久化设置，不直接调用 GPU。
--------------------------------------------------------------------------------

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

--- 判断主题 ID 是否已注册。
function registry.has(id)
    return themes[id] ~= nil
end

--- 返回指定主题；未知 ID 回退到当前主题。
function registry.get(id)
    return themes[id] or themes[currentId]
end

--- 按配置顺序返回全部可用主题。
function registry.list()
    local out = {}
    for _, id in ipairs(order) do
        if themes[id] then out[#out + 1] = themes[id] end
    end
    return out
end

--- 返回当前主题对象。
function registry.current()
    return themes[currentId]
end

--- 返回当前主题 ID。
function registry.currentId()
    return currentId
end

--- 切换当前主题；未知 ID 保持原主题。
function registry.set(id)
    if themes[id] then currentId = id end
    return themes[currentId]
end

--- 按注册顺序切换到下一个主题。
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
