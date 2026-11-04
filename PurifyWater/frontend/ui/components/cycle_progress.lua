--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/cycle_progress.lua
--
-- 定位：总览页主机周期进度条独立组件。
-- 功能：只重绘进度条和百分比所在的单行小区域。
-- 边界：只展示 cycle ViewModel，不读取硬件，不参与等级状态布局。
--------------------------------------------------------------------------------

local Component = require("frontend.ui.base")

local CycleProgress = {}

--- 创建独立周期进度条组件。
function CycleProgress.new()
    local self = Component.new("cycle", { ratio = 0, text = "-" })
    self.barRect = { x = 1, y = 1, w = 0, h = 1 }
    self.pctX = 1
    self.pctW = 7
    self.showBar = false
    self.setLayout = CycleProgress.setLayout
    self.fingerprint = CycleProgress.fingerprint
    self.render = CycleProgress.render
    return self
end

--- 按状态组件算出的标题行布局设置动态区域。
function CycleProgress:setLayout(layout)
    self.barRect = {
        x = layout.barX,
        y = layout.titleY,
        w = layout.barW,
        h = 1,
    }
    self.pctX = layout.pctX
    self.pctW = layout.pctW
    self.showBar = layout.barW >= 8

    local x = self.showBar and layout.barX or layout.pctX
    self:setRect({
        x = x,
        y = layout.titleY,
        w = math.max(1, layout.pctX + layout.pctW - x),
        h = 1,
    })
end

--- 生成只影响周期条自身的渲染指纹。
function CycleProgress:fingerprint(context)
    if context.ui.detailLevel then
        return table.concat({ self.key, "detail", self.rect.x, self.rect.y }, ":")
    end
    local ratio = tonumber(self.props.ratio) or 0
    return table.concat({
        self.key,
        self.rect.x, self.rect.y, self.rect.w, self.rect.h,
        context.themeId,
        tostring(self.showBar),
        tostring(self.barRect.w),
        tostring(self.pctW),
        tostring(math.floor(math.max(0, math.min(1, ratio)) * 100 + 0.5)),
        tostring(self.props.text or "-"),
        tostring(self.props.revision or "-"),
    }, "\x1f")
end

--- 只绘制动态进度条和百分比区域。
function CycleProgress:render(context)
    if context.ui.detailLevel then return end
    local p = context.painter
    p:fill(self.rect, "surface")
    if self.showBar then
        p:bar(self.barRect, self.props.ratio or 0,
            "cycleFill", "cycleTrack", "cycleTrack")
    end
    p:textRight(self.pctX, self.rect.y, self.pctW,
        tostring(self.props.text or "-"), "accent", "surface")
end

return CycleProgress
