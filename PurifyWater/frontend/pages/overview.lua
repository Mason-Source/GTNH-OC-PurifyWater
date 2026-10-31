local TabBar = require("frontend.ui.components.tabbar")
local Control = require("frontend.ui.components.control")
local Status = require("frontend.ui.components.status")
local Chart = require("frontend.ui.components.chart")
local LogPanel = require("frontend.ui.components.log")

local Page = {}
Page.__index = Page

function Page.new()
    local self = setmetatable({}, Page)
    self.tabbar = TabBar.new()
    self.control = Control.new()
    self.status = Status.new()
    self.chart = Chart.new()
    self.log = LogPanel.new()
    self.components = { self.tabbar, self.control, self.status, self.chart, self.log }
    return self
end

function Page:update(view)
    self.view = view
    self.tabbar:setProps({ page = "overview" })
    self.control:setProps(view.control or {})
    self.status:setProps({ levels = view.levels or {}, cycle = view.cycle or {} })
    self.chart:setProps({ history = view.chart and view.chart.history or { times = {}, values = {} } })
    self.log:setProps({ log = view.logs })
end

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
    self.chart:setRect({ x = rightX, y = bodyY + statusH + gap, w = rightW, h = chartH })
end

return Page
