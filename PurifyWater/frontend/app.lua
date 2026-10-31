-- 前端应用外壳：拉取读模型、构造页面 ViewModel、协调增量渲染。
local component = require("component")
local clock = require("services.clock")
local config = require("shared.config")
local overview_model = require("frontend.model.overview")
local theme_registry = require("frontend.theme.registry")
local Painter = require("frontend.ui.painter")
local Renderer = require("frontend.ui.renderer")
local OverviewPage = require("frontend.pages.overview")
local input = require("frontend.input")

local app = {
    booted = false,
    revision = nil,
    pageName = "overview",
    page = nil,
    pages = nil,
    views = {},
    view = nil,
    painter = nil,
    renderer = nil,
    theme = nil,
    viewport = { width = 0, height = 0 },
    baseResolution = nil,
    readOnly = false,
    snapshotReader = nil,
    ui = {
        detailLevel = nil,
        chartLevel = 0,
        editLevel = nil,
        editField = nil,
        editBuf = "",
        producePage = 1,
        produceCandidatePage = 1,
    },
    actionHandler = nil,
    observer = nil,
    lastInputAt = nil,
}

local function readViewport()
    local width, height = component.gpu.getResolution()
    app.viewport.width = width
    app.viewport.height = height
end

local function applyResolution()
    local gpu = component.gpu
    local width, height = gpu.getResolution()
    app.baseResolution = { width = width, height = height }

    local targetW = config.UI.RESOLUTION_WIDTH or 0
    local targetH = config.UI.RESOLUTION_HEIGHT or 0
    if targetW <= 0 and targetH <= 0 then return end

    local wantW = targetW > 0 and targetW or width
    local wantH = targetH > 0 and targetH or height
    if wantW ~= width or wantH ~= height then
        pcall(gpu.setResolution, wantW, wantH)
    end
end

function app.restoreResolution()
    local base = app.baseResolution
    if not base or not component.gpu then return end
    local width, height = component.gpu.getResolution()
    if width ~= base.width or height ~= base.height then
        pcall(component.gpu.setResolution, base.width, base.height)
    end
end

function app.layout(width, height)
    app.viewport.width = width
    app.viewport.height = height
    if app.page then app.page:layout(width, height) end
    if app.renderer then app.renderer:invalidateAll() end
end

function app.setSnapshotReader(reader)
    app.snapshotReader = reader
end

function app.boot(options)
    options = options or {}
    if options.readOnly then app.readOnly = true end
    if not component.gpu then return false end

    app.theme = theme_registry.set(options.theme or config.UI.DEFAULT_THEME or "dark")
    app.painter = Painter.new(component.gpu, app.theme)
    app.renderer = Renderer.new(app.painter)
    app.pages = { overview = OverviewPage.new() }
    if not app.readOnly then
        local ConfigPage = require("frontend.pages.config")
        app.pages.config = ConfigPage.new()
    end
    app.page = app.pages[app.pageName]
    applyResolution()
    readViewport()
    app.page:layout(app.viewport.width, app.viewport.height)
    app.renderer:invalidateAll()
    app.booted = true
    return true
end

function app.setPage(name)
    if app.readOnly and name ~= "overview" then return false end
    local target = app.pages and app.pages[name]
    if not target then return false end
    if app.pageName ~= name then
        if app.actionHandler then app.actionHandler("produce_bind_cancel") end
        app.ui.editLevel, app.ui.editField, app.ui.editBuf = nil, nil, ""
    end
    app.pageName = name
    app.page = target
    if app.views[name] then app.page:update(app.views[name]) end
    app.page:layout(app.viewport.width, app.viewport.height)
    app.renderer:invalidateAll()
    return true
end

function app.togglePage()
    if app.readOnly then return false end
    return app.setPage(app.pageName == "overview" and "config" or "overview")
end

function app.setTheme(id)
    if not theme_registry.has(id) then return false end
    app.theme = theme_registry.set(id)
    app.renderer:setTheme(app.theme)
    app.renderer:invalidateAll()
    return true
end

function app.setActionHandler(handler)
    app.actionHandler = handler
end

function app.setObserver(observer)
    app.observer = observer
end

function app.frameInput()
    return app.frame("input")
end

function app.frameData()
    return app.frame("data")
end

function app.frame(reason)
    if not app.booted then return 0 end
    local startedCpu = clock.cpuTime()
    local startedReal = clock.realTime()
    local snapshot
    if app.snapshotReader then
        snapshot = app.snapshotReader()
    else
        snapshot = require("services.read_model").snapshot()
    end
    if not snapshot then return 0 end

    local themeId = snapshot.system and snapshot.system.theme
    if themeId and theme_registry.has(themeId) and themeId ~= app.theme.id then
        app.theme = theme_registry.set(themeId)
        app.renderer:setTheme(app.theme)
        app.renderer:invalidateAll()
    end

    if snapshot.revision ~= app.revision then
        app.revision = snapshot.revision
        app.views.overview = overview_model.build(snapshot)
        if not app.readOnly then
            app.views.config = require("frontend.model.config").build(snapshot)
        end
        app.view = app.views[app.pageName]
        app.page:update(app.view)
    end

    app.renderer:setTheme(app.theme)
    local draws = app.renderer:render(app.page.components, app)
    local latency = app.lastInputAt and ((startedReal - app.lastInputAt) * 1000) or nil
    if reason == "input" then app.lastInputAt = nil end
    if app.observer then
        app.observer("frame", {
            reason = reason or "manual",
            draws = draws,
            elapsedMs = (clock.cpuTime() - startedCpu) * 1000,
            latencyMs = latency,
            revision = app.revision,
            page = app.pageName,
        })
    end
    return draws
end

function app.handle(signal)
    local startedCpu = clock.cpuTime()
    local startedReal = clock.realTime()
    app.lastInputAt = startedReal
    local handled = input.handle(app, signal)
    if app.observer then
        app.observer("input", {
            name = signal and signal[1] or "unknown",
            handled = handled == true,
            elapsedMs = (clock.cpuTime() - startedCpu) * 1000,
        })
    end
    return handled
end

return app