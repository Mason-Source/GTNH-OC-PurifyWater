--------------------------------------------------------------------------------
-- PurifyWater/frontend/pages/overview.lua
--
-- 定位：总览页组件容器。
-- 功能：组合页签、控制面板、等级状态、历史图表和日志面板，并负责响应式布局。
-- 边界：不处理输入或业务命令；只消费 ViewModel。
--------------------------------------------------------------------------------

local unicode = require("unicode")
local TabBar = require("frontend.ui.components.tabbar")
local Control = require("frontend.ui.components.control")
local Status = require("frontend.ui.components.status")
local CycleProgress = require("frontend.ui.components.cycle_progress")
local Chart = require("frontend.ui.components.chart")
local LogPanel = require("frontend.ui.components.log")

local Page = {}
Page.__index = Page

--- 创建总览页及其组件实例。
function Page.new()
    local self = setmetatable({}, Page)
    self.tabbar = TabBar.new()
    self.control = Control.new()
    self.status = Status.new()
    self.cycle = CycleProgress.new()
    self.chart = Chart.new()
    self.log = LogPanel.new()
    self.components = { self.tabbar, self.control, self.status, self.cycle, self.chart, self.log }
    return self
end

--- 用总览页 ViewModel 更新子组件属性。
function Page:update(view)
    self.view = view
    self.tabbar:setProps({ page = "overview" })
    self.control:setProps(view.control or {})
    self.status:setProps({ levels = view.levels or {} })
    local cycle = view.cycle or {}
    self.cycle:setProps({
        ratio = cycle.ratio,
        text = cycle.text,
        revision = view.revision,
    })
    self.chart:setProps({ history = view.chart and view.chart.history or { times = {}, values = {} } })
    self.log:setProps({ log = view.logs })
end

--- 根据终端尺寸计算总览页各组件矩形。
function Page:layout(width, height)
    local bodyY = 2
    local bodyH = math.max(3, height - 1)
    local leftW = math.max(26, math.min(math.floor(width * 0.30), 46, width - 40))
    local gap = 1
    local rightX = leftW + 2
    local rightW = math.max(1, width - rightX + 1)

    self.tabbar:setRect({ x = 1, y = 1, w = width, h = 1 })

    local controlH = math.min(18, math.max(6, bodyH - 7))
    local logH = math.max(3, bodyH - controlH - gap)
    self.control:setRect({ x = 1, y = bodyY, w = leftW, h = controlH })
    self.log:setRect({ x = 1, y = bodyY + controlH + gap, w = leftW, h = logH })

    local statusH = bodyH >= 30 and 19 or 12
    local chartH = math.max(4, bodyH - statusH - gap)
    self.status:setRect({ x = rightX, y = bodyY, w = rightW, h = statusH })
    local cycleLayout = Status.layoutCycle(self.status.rect, function(text)
        return unicode.wlen(tostring(text or ""))
    end)
    self.cycle:setLayout(cycleLayout)
    self.chart:setRect({ x = rightX, y = bodyY + statusH + gap, w = rightW, h = chartH })
end

return Page
