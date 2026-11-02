--------------------------------------------------------------------------------
-- PurifyWater/frontend/pages/config.lua
--
-- 定位：配置页组件容器。
-- 功能：组合页签、配置表、运行设置和主题卡片，并负责页面布局。
-- 边界：不处理输入或业务命令；动作由 input 路由。
--------------------------------------------------------------------------------

local TabBar = require("frontend.ui.components.tabbar")
local ConfigTable = require("frontend.ui.components.config_table")
local Settings = require("frontend.ui.components.settings")
local ThemeCard = require("frontend.ui.components.theme_card")

local Page = {}
Page.__index = Page

--- 创建配置页及其组件实例。
function Page.new()
    local self = setmetatable({}, Page)
    self.tabbar = TabBar.new()
    self.table = ConfigTable.new()
    self.settings = Settings.new()
    self.theme_card = ThemeCard.new()
    self.components = { self.tabbar, self.table, self.settings, self.theme_card }
    return self
end

--- 用配置页 ViewModel 更新子组件属性。
function Page:update(view)
    self.view = view
    self.tabbar:setProps({ page = "config" })
    self.table:setProps({
        rows = view.rows or {},
        system = view.system or {},
        net = view.net or {},
        produce = view.produce or { levels = {} },
    })
    self.settings:setProps({ settings = view.settings or {} })
end

--- 根据终端尺寸计算配置页各组件矩形。
function Page:layout(width, height)
    local bodyY = 2
    local bodyH = math.max(3, height - 1)
    local configH = math.min(27, math.max(15, bodyH - 6))
    local settingsY = bodyY + configH + 1
    local settingsH = math.min(5, math.max(0, height - settingsY + 1))
    local bottomW = math.max(1, width - 2)
    local settingsW = math.floor(bottomW * 0.55)
    local themeX = 2 + settingsW + 1
    local themeW = math.max(1, width - themeX)

    self.tabbar:setRect({ x = 1, y = 1, w = width, h = 1 })
    self.table:setRect({ x = 2, y = bodyY, w = width - 2, h = configH })
    self.settings:setRect({ x = 2, y = settingsY, w = settingsW, h = settingsH })
    self.theme_card:setRect({ x = themeX, y = settingsY, w = themeW, h = settingsH })
end

return Page
