--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/base.lua
--
-- 定位：轻量 UI 组件基类工厂。
-- 功能：为保留式组件提供 key、props、rect 和属性更新方法。
-- 边界：不使用继承链，不实现绘制或命中逻辑。
--------------------------------------------------------------------------------

local Component = {}

--- 替换组件属性表。
function Component.setProps(self, props)
    self.props = props or {}
end

--- 更新组件的屏幕矩形。
function Component.setRect(self, rect)
    self.rect = rect or self.rect
end

--- 创建一个带默认矩形和属性方法的轻量组件。
function Component.new(key, props)
    return {
        key = key,
        props = props or {},
        rect = { x = 1, y = 1, w = 0, h = 0 },
        setProps = Component.setProps,
        setRect = Component.setRect,
    }
end

return Component
