--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/renderer.lua
--
-- 定位：保留式增量渲染器。
-- 功能：按组件指纹跳过未变化组件，清理失效命中框并转发触摸命中。
-- 边界：不构造 ViewModel，不修改业务状态。
--------------------------------------------------------------------------------

local Renderer = {}
Renderer.__index = Renderer

--- 创建保留式渲染器。
function Renderer.new(painter)
    return setmetatable({
        painter = painter,
        fingerprints = {},
        hitboxesByKey = {},
        hitboxes = {},
        forceAll = true,
    }, Renderer)
end

--- 把主题同步给底层绘制器。
function Renderer:setTheme(theme)
    self.painter:setTheme(theme)
end

--- 使全部组件和命中框在下一帧重建。
function Renderer:invalidateAll()
    self.forceAll = true
end

--- 使指定组件失效；无 key 时整页失效。
function Renderer:invalidate(key)
    if key then self.fingerprints[key] = nil else self.forceAll = true end
end

--- 创建组件渲染上下文，并收集本次绘制产生的命中框。
local function makeContext(renderer, app)
    local context = {
        painter = renderer.painter,
        theme = app.theme,
        themeId = app.theme.id,
        ui = app.ui,
        viewport = app.viewport,
        readOnly = app.readOnly == true,
        hitboxes = {},
    }

    function context:hit(action, rect)
        self.hitboxes[#self.hitboxes + 1] = {
            action = action,
            rect = rect,
        }
    end

    return context
end

--- 按组件指纹渲染脏组件并重建命中框。
function Renderer:render(components, app)
    local context = makeContext(self, app)

    if self.forceAll then
        self.painter:clear({
            x = 1,
            y = 1,
            w = app.viewport.width,
            h = app.viewport.height,
        })
        self.fingerprints = {}
        self.hitboxesByKey = {}
    end

    local drawn = 0
    for _, component in ipairs(components or {}) do
        local key = component.key
        local fingerprint = component:fingerprint(context)
        if self.forceAll or self.fingerprints[key] ~= fingerprint then
            context.hitboxes = {}
            component:render(context)
            self.hitboxesByKey[key] = context.hitboxes
            self.fingerprints[key] = fingerprint
            drawn = drawn + 1
        end
    end

    self.hitboxes = {}
    for _, component in ipairs(components or {}) do
        for _, box in ipairs(self.hitboxesByKey[component.key] or {}) do
            self.hitboxes[#self.hitboxes + 1] = box
        end
    end
    self.forceAll = false
    return drawn
end

--- 把屏幕坐标转换为最上层可交互动作。
function Renderer:hit(x, y)
    for _, box in ipairs(self.hitboxes) do
        local rect = box.rect
        if x >= rect.x and x < rect.x + rect.w
            and y >= rect.y and y < rect.y + rect.h then
            return box.action, box
        end
    end
end

return Renderer
