local fstate        = require("frontend.state")
local theme         = require("frontend.theme")
local layout        = require("frontend.layout")
local viewmodel     = require("frontend.viewmodel")
local input         = require("frontend.input")
local CONFIG        = require("shared.config")
local logs          = require("shared.logs")
local scheduler     = require("core.scheduler")
local tabBarPanel   = require("frontend.panels.tabbar")
local controlPanel  = require("frontend.panels.control")
local statusPanel   = require("frontend.panels.status")
local chartPanel    = require("frontend.panels.chart")
local logPanel      = require("frontend.panels.log")
local configPanel   = require("frontend.panels.config")
local editlinePanel = require("frontend.panels.editline")
local keypadPanel   = require("frontend.panels.keypad")
local render        = {}
local PANELS        = {
    tabBar   = { draw = tabBarPanel.draw, fingerprint = tabBarPanel.fingerprint },
    control  = { draw = controlPanel.draw, fingerprint = controlPanel.fingerprint },
    status   = { draw = statusPanel.draw, fingerprint = statusPanel.fingerprint },
    chart    = { draw = chartPanel.draw, fingerprint = chartPanel.fingerprint },
    log      = { draw = logPanel.draw, fingerprint = logPanel.fingerprint },
    config   = { draw = configPanel.draw, fingerprint = configPanel.fingerprint },
    editline = { draw = editlinePanel.draw, fingerprint = editlinePanel.fingerprint },
    keypad   = { draw = keypadPanel.draw, fingerprint = keypadPanel.fingerprint }
}
local TAB_PANELS    = {
    overview = { "tabBar", "control", "status", "chart", "log" },
    config   = { "tabBar", "config", "editline", "keypad" }
}
function render.applyResolution()
    local gpu = fstate.gpu
    if not gpu then return end
    local w, h            = gpu.getResolution()
    fstate.baseResolution = { width = w, height = h }
    local targetW         = CONFIG.UI.RESOLUTION_WIDTH or 0
    local targetH         = CONFIG.UI.RESOLUTION_HEIGHT or 0
    if targetW > 0 or targetH > 0 then
        local wantW = (targetW > 0) and targetW or w
        local wantH = (targetH > 0) and targetH or h
        if wantW ~= w or wantH ~= h then
            local ok, err = pcall(gpu.setResolution, wantW, wantH)
            if not ok then
                logs.warn("改分辨率失败（屏幕/显卡不支持），保持原样：" .. tostring(err))
            end
        end
    end
end
function render.restoreResolution()
    local base = fstate.baseResolution
    if not base or not fstate.gpu then return end
    local w, h = fstate.gpu.getResolution()
    if w ~= base.width or h ~= base.height then
        pcall(fstate.gpu.setResolution, base.width, base.height)
    end
end
function render.boot()
    fstate.gpu = require("component").gpu
    render.applyResolution()
    layout.calculate()
    scheduler.on("key_down", function(payload) input.handle("key_down", payload) end)
    scheduler.on("touch", function(payload) input.handle("touch", payload) end)
    scheduler.on("screen_resized", function() layout.calculate() end)
    fstate.invalidateAll()
end
function render.renderAll(forceAll)
    local fps = fstate.render.fingerprints
    forceAll  = forceAll or fstate.render.forceAll
    if forceAll then
        fstate.gpu.setBackground(theme.COLORS.BG)
        fstate.gpu.fill(1, 1, fstate.W, fstate.H, " ")
        for name in pairs(fps) do fps[name] = nil end
        fstate.clearSubs()
        fstate.clearHitboxes()
    end
    local data = fstate.lastData
    local list = TAB_PANELS[fstate.currentTab] or TAB_PANELS.overview
    for _, name in ipairs(list) do
        local panel = PANELS[name]
        if panel then
            local fp = panel.fingerprint(data)
            if forceAll or fps[name] ~= fp then
                panel.draw(data)
                fps[name] = fp
            end
        end
    end
    fstate.render.forceAll = false
end
function render.frame()
    local data = viewmodel.build()
    input.attach(data)
    render.renderAll()
end
return render
