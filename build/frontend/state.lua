local fstate = {
    gpu            = nil,
    W              = 0,
    H              = 0,
    grid           = { rows = {}, cols = {} },
    areas          = {},
    currentTab     = "overview",               
    tabs           = {},
    buttons        = {},
    levelRows      = {},
    detailLevel    = nil,
    chartLevel     = 0,
    chartChips     = {},
    logTitle       = nil,
    configRows     = {},
    checkCells     = {},
    keyCells       = {},
    configSel      = nil,
    configBuf      = nil,
    lastData       = nil,
    baseResolution = nil,
    render         = { fingerprints = {}, forceAll = true, subs = {} }
}
function fstate.subDirty(panel, sub, fp)
    local subs = fstate.render.subs[panel]
    if not subs then
        subs = {}
        fstate.render.subs[panel] = subs
    end
    local key = tostring(fp)
    if subs[sub] == key then return false end
    subs[sub] = key
    return true
end
function fstate.clearSubs()
    fstate.render.subs = {}
end
function fstate.invalidateAll()
    fstate.render.forceAll = true
end
function fstate.clearHitboxes()
    fstate.buttons, fstate.tabs, fstate.chartChips = {}, {}, {}
    fstate.checkCells, fstate.configRows, fstate.keyCells = {}, {}, {}
    fstate.levelRows = {}
    fstate.logTitle = nil
end
function fstate.hit(box, x, y)
    if not box then return false end
    return x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.h
end
function fstate.buttonAt(x, y)
    for name, box in pairs(fstate.buttons) do
        if fstate.hit(box, x, y) then return name, box end
    end
    return nil, nil
end
return fstate
