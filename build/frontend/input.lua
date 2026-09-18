local utils     = require("shared.utils")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local api       = require("backend.api")
local viewmodel = require("frontend.viewmodel")
local fstate    = require("frontend.state")
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
    fstate.configSel, fstate.configBuf = nil, nil
    fstate.invalidateAll()
end
local function selectLevel(level)
    local row        = fstate.lastData and fstate.lastData.levels[level]
    local milli      = row and (row.rule.threshold or 0) or 0
    fstate.configSel = level
    fstate.configBuf = tostring(math.floor(milli / 1000))
end
local function applyKey(key)
    local limit = CONFIG.UI.MAX_THRESHOLD_KILO or 100000000000000
    if key.kind == "cancel" then
        fstate.configSel, fstate.configBuf = nil, nil
        logs.debug("[调试] 退出编辑（用户点了 ✘）")
        return nil
    end
    if not fstate.configSel then return nil end
    if key.kind == "commit" then
        local value = tonumber(fstate.configBuf or "")
        if not value then
            logs.ui("还没填数字，未保存")
            return nil
        end
        if value >= limit then
            logs.ui("超过上限（≥ 1e14 kL），未保存")
            return nil
        end
        return "commit"
    end
    local buf = fstate.configBuf or ""
    if key.kind == "digit" then
        if buf == "0" then buf = "" end 
        buf = buf .. key.value
    elseif key.kind == "mul" or key.kind == "div" then
        local n     = tonumber(buf) or 0
        local scale = tonumber(key.value) or 1
        buf         = tostring((key.kind == "mul") and (n * scale) or math.floor(n / scale))
    elseif key.kind == "set" then
        buf = key.value
    elseif key.kind == "back" then
        buf = buf:sub(1, math.max(0, #buf - 1))
    elseif key.kind == "clear" then
        buf = ""
    elseif key.kind == "copy" then
        local row = fstate.lastData and fstate.lastData.levels[fstate.configSel - 1]
        if row then buf = tostring(math.floor((row.rule.threshold or 0) / 1000)) end
    end
    if buf ~= "" then
        local value = tonumber(buf)
        if not value or value >= limit then
            logs.ui("超过上限（≥ 1e14 kL），这一下没生效")
            return nil
        end
    end
    fstate.configBuf = buf
    return nil
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
    elseif utils.isKey(char, code, "p") then
        fire("priority_toggle")
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
    if fstate.currentTab == "overview" and fstate.hit(fstate.areas.status, x, y) then
        if fstate.detailLevel then
            fstate.detailLevel = nil
        else
            for level, box in pairs(fstate.levelRows or {}) do
                if fstate.hit(box, x, y) then
                    fstate.detailLevel = level
                    break
                end
            end
        end
        return
    end
    if fstate.hit(fstate.logTitle, x, y) then
        fire("log_level_toggle")
        return
    end
    for level, box in pairs(fstate.chartChips or {}) do
        if fstate.hit(box, x, y) then
            setChartLevel(level)
            return
        end
    end
    if fstate.currentTab == "config" then
        for _, box in ipairs(fstate.keyCells or {}) do
            if fstate.hit(box, x, y) then
                local level = fstate.configSel
                if applyKey(box) == "commit" then
                    local kilo = tonumber(fstate.configBuf or "")
                    if kilo and level then
                        fire("level_rules_set", level, kilo * 1000, nil)
                        fstate.configSel, fstate.configBuf = nil, nil
                    end
                end
                return
            end
        end
        for level, box in pairs(fstate.checkCells or {}) do
            if fstate.hit(box, x, y) then
                fire("level_enabled_toggle", level)
                return
            end
        end
        for level, box in pairs(fstate.configRows or {}) do
            if fstate.hit(box, x, y) then
                selectLevel(level)
                return
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
