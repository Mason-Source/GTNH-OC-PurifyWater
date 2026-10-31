-- 保留式渲染器：按组件指纹比较，只重画脏组件。
local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(painter)
    return setmetatable({
        painter = painter,
        fingerprints = {},
        hitboxesByKey = {},
        hitboxes = {},
        forceAll = true,
    }, Renderer)
end

function Renderer:setTheme(theme)
    self.painter:setTheme(theme)
end

function Renderer:invalidateAll()
    self.forceAll = true
end

function Renderer:invalidate(key)
    if key then self.fingerprints[key] = nil else self.forceAll = true end
end

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
