-- 保留式组件基类：字段组合，不使用继承，避免隐藏的重复方法。
local Component = {}

function Component.setProps(self, props)
    self.props = props or {}
end

function Component.setRect(self, rect)
    self.rect = rect or self.rect
end

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
