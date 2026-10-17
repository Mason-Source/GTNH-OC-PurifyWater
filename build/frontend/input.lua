local utils     = require("shared.utils")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local api       = require("backend.api")
local viewmodel = require("frontend.viewmodel")
local fstate    = require("frontend.state")
local viewinput = require("frontend.viewinput")
local input     = {}
local function fire(command, ...)
    local ok, text = api.exec(command, ...)
    if not ok and text and text ~= "" then
        logs.ui(tostring(text))
    end
    viewmodel.expire()
    return ok
end
local function switchTab(tab)
    if fstate.currentTab == tab then return end
    fstate.currentTab = tab
    fstate.editLevel, fstate.editField, fstate.editBuf = nil, nil, nil
    fstate.invalidateAll()
end
local function selectCell(level, field)
    local row = fstate.lastData and fstate.lastData.levels[level]
    fstate.editLevel, fstate.editField = level, field
    if field == "threshold" then
        local milli    = (row and row.rule.threshold) or 0
        fstate.editBuf = tostring(math.floor(milli / 1000))
    elseif field == "weight" then
        fstate.editBuf = tostring(math.floor(tonumber(row and row.weight) or 0))
    else
        fstate.editBuf = nil
    end
end
local function selectFactor()
    local sys = fstate.lastData and fstate.lastData.system
    fstate.editLevel, fstate.editField = nil, "factor"
    fstate.editBuf = tostring(math.floor(tonumber(sys and sys.energyFactor) or 100))
end
local function selectStrength()
    local netState = fstate.lastData and fstate.lastData.net
    fstate.editLevel, fstate.editField = nil, "strength"
    fstate.editBuf = tostring(math.floor(tonumber(netState and netState.strength) or CONFIG.NET.STRENGTH))
end
local function clearEdit()
    fstate.editLevel, fstate.editField, fstate.editBuf = nil, nil, nil
end
local function applyCell(level, field)
    if field == "produce" then
        selectCell(level, "produce")
        fstate.producePage = 1
        return
    end
    if field ~= "enabled" then
        selectCell(level, field)
        return
    end
    local row = fstate.lastData and fstate.lastData.levels[level]
    if not row then return end
    fire("level_enabled_set", level, not (row.rule.enabled == true))
end
local function applyKey(key)
    local field, level = fstate.editField, fstate.editLevel
    if not field then return end
    if field ~= "factor" and field ~= "strength" and not level then return end
    local kind = key.kind
    if kind == "cancel" then
        logs.debug("退出编辑（✘）")
        clearEdit()
        return
    end
    if field == "boost" then
        if kind == "set_boost" then
            fire("t7_boost_set", tonumber(key.value))
            clearEdit()
        end
        return
    end
    local isThreshold = (field == "threshold")
    local isFactor    = (field == "factor")
    local isStrength  = (field == "strength")
    local limit       = isThreshold and (CONFIG.UI.MAX_THRESHOLD_KILO or 100000000000000)
        or isFactor and CONFIG.ENERGY.FACTOR_MAX
        or isStrength and CONFIG.NET.STRENGTH_MAX
        or (CONFIG.RATES.MAX_WEIGHT or 100)
    if kind == "commit" then
        local value = tonumber(fstate.editBuf or "")
        if not value then
            logs.ui("未填数字，未保存")
            return
        end
        if isThreshold then
            if value >= limit then
                logs.ui("超过上限（≥ 1e14 kL），未保存")
                return
            end
            fire("level_rules_set", level, value * 1000, nil)
        elseif isFactor then
            if value < CONFIG.ENERGY.FACTOR_MIN or value > limit then
                logs.ui(string.format("利用因子需为 %d-%d 的整数，未保存",
                    CONFIG.ENERGY.FACTOR_MIN, limit))
                return
            end
            fire("energy_factor_set", value)
        elseif isStrength then
            if value < 0 or value > limit then
                logs.ui(string.format("无线范围需为 0-%d 的整数（方块），未保存", limit))
                return
            end
            fire("net_strength_set", value) 
        else
            if value < 0 or value > limit then
                logs.ui(string.format("权重需为 0-%d 的整数，未保存", limit))
                return
            end
            fire("weight_set", level, value)
        end
        clearEdit()
        return
    end
    local buf = fstate.editBuf or ""
    if kind == "digit" then
        if buf == "0" then buf = "" end 
        buf = buf .. key.value
    elseif kind == "mul" or kind == "div" then
        local n     = tonumber(buf) or 0
        local scale = tonumber(key.value) or 1
        buf         = tostring((kind == "mul") and (n * scale) or math.floor(n / scale))
    elseif kind == "set" then
        buf = key.value
    elseif kind == "back" then
        buf = buf:sub(1, math.max(0, #buf - 1))
    elseif kind == "clear" then
        buf = ""
    elseif kind == "copy" then
        local prev = fstate.lastData and fstate.lastData.levels[level - 1]
        if prev then buf = tostring(math.floor((prev.rule.threshold or 0) / 1000)) end
    end
    if buf ~= "" then
        local value = tonumber(buf)
        local over
        if not value then over = true
        elseif isThreshold then over = (value >= limit)
        else over = (value > limit) end
        if over then
            local name = isFactor and "利用因子" or isStrength and "无线范围" or "权重"
            logs.ui(isThreshold and "超过上限（≥ 1e14 kL），未生效"
                or string.format("%s上限 %d，未生效", name, limit))
            return
        end
    end
    fstate.editBuf = buf
end
local function setChartLevel(level)
    fstate.chartLevel = level
    viewmodel.expire()
end
local function onKey(char, code)
    if utils.isKey(char, code, "x") then
        local blocked = viewmodel.startBlockedReason(fstate.lastData)
        if blocked then
            logs.ui("启动被拦下：" .. blocked)
        else
            fire("system_toggle")
        end
    elseif utils.isKey(char, code, "r") then
        fire("refresh")
    elseif utils.isKey(char, code, "t") then
        switchTab((fstate.currentTab == "overview") and "config" or "overview")
    else
        local key   = utils.keyChar(char)
        local level = key and tonumber(key)
        if level and level >= 0 and level <= constants.LEVEL_COUNT then
            setChartLevel(level)
        end
    end
end
local function onClick(x, y)
    for key, box in pairs(fstate.tabs) do
        if fstate.hit(box, x, y) then
            switchTab(key)
            return
        end
    end
    if viewinput.statusArea(x, y) then return end
    if fstate.hit(fstate.logTitle, x, y) then
        fire("log_level_toggle")
        return
    end
    if viewinput.chartChip(x, y) then
        viewmodel.expire()
        return
    end
    if fstate.currentTab == "config" then
        for _, box in ipairs(fstate.keys or {}) do
            if fstate.hit(box, x, y) then
                applyKey(box)
                return
            end
        end
        for _, box in ipairs(fstate.produceHits or {}) do
            if fstate.hit(box, x, y) then
                if box.act == "page" then
                    fstate.producePage = (fstate.producePage or 1) + (tonumber(box.value) or 0)
                    viewmodel.expire()
                elseif box.act == "bind" then
                    fire("produce_bind_begin", fstate.editLevel, box.machine)
                elseif box.act == "unbind" then
                    fire("produce_unbind", box.machine)
                elseif box.act == "cancel" then
                    fire("produce_bind_cancel")
                elseif box.act == "toggle" then
                    local row = fstate.lastData and fstate.lastData.levels[fstate.editLevel]
                    fire("level_produce_set", fstate.editLevel, not (row and row.produceEnabled == true))
                end
                return
            end
        end
        if fstate.hit(fstate.strengthCell, x, y) then
            selectStrength()
            return
        end
        if fstate.hit(fstate.factorCell, x, y) then
            selectFactor()
            return
        end
        if fstate.hit(fstate.autostartRow, x, y) then
            fire("autostart_toggle")
            return
        end
        for level, cell in pairs(fstate.cells or {}) do
            for field, box in pairs(cell) do
                if fstate.hit(box, x, y) then
                    applyCell(level, field)
                    return
                end
            end
        end
        return
    end
    local _, box = fstate.buttonAt(x, y)
    if box and box.action then
        fire(box.action)
    end
end
function input.handle(name, payload)
    payload = payload or {}
    if name == "key_down" then
        onKey(payload[3], payload[4])
        return true
    end
    if name == "touch" then
        local x, y = payload[3], payload[4]
        if type(x) == "number" and type(y) == "number" then
            onClick(x, y)
            return true
        end
    end
    return false
end
function input.attach(data)
    fstate.lastData = data
end
return input
