--------------------------------------------------------------------------------
-- PurifyWater/frontend/input.lua
--
-- 定位：平台输入信号到前端动作的路由器。
-- 功能：处理键鼠/触摸信号，维护编辑状态，把页面操作转换为前端动作或业务命令。
-- 边界：不直接访问硬件或业务服务，只调用 app 暴露的接口和 actionHandler。
--------------------------------------------------------------------------------

local CONFIG = require("shared.config")

local input = {}

local function configView(app)
    return app.views and app.views.config or {}
end

local function clearEdit(app)
    app.ui.editLevel = nil
    app.ui.editField = nil
    app.ui.editBuf = ""
end

local function currentBuffer(app, field, level)
    local view = configView(app)
    if field == "threshold" then
        return tostring(tonumber(view.rows and view.rows[level] and view.rows[level].thresholdK) or 0)
    elseif field == "weight" then
        return tostring(tonumber(view.rows and view.rows[level] and view.rows[level].weight) or 0)
    elseif field == "factor" then
        return tostring(tonumber(view.system and view.system.energyFactor) or CONFIG.ENERGY.FACTOR_DEFAULT)
    elseif field == "strength" then
        return tostring(tonumber(view.net and view.net.strength) or 0)
    end
    return ""
end

local function limitFor(field)
    if field == "threshold" then return 100000000000000 end
    if field == "factor" then return CONFIG.ENERGY.FACTOR_MAX end
    if field == "strength" then return CONFIG.NET.STRENGTH_MAX end
    return CONFIG.RATES.MAX_WEIGHT
end

local function leaveProduceSelection(app)
    if app.ui.editField == "produce" and app.actionHandler then
        app.actionHandler("produce_bind_cancel")
    end
end

local function selectCell(app, level, field)
    leaveProduceSelection(app)
    if app.ui.editLevel == level and app.ui.editField == field then
        clearEdit(app)
    else
        app.ui.editLevel = level
        app.ui.editField = field
        app.ui.editBuf = currentBuffer(app, field, level)
        if field == "produce" then
            app.ui.producePage = 1
            app.ui.produceCandidatePage = 1
        end
    end
    app.renderer:invalidate("config_table")
    return true
end

local function selectGlobal(app, field)
    leaveProduceSelection(app)
    if app.ui.editLevel == nil and app.ui.editField == field then
        clearEdit(app)
    else
        app.ui.editLevel = nil
        app.ui.editField = field
        app.ui.editBuf = currentBuffer(app, field, nil)
    end
    app.renderer:invalidate("config_table")
    return true
end

local function applyKeypad(app, action)
    local field, level = app.ui.editField, app.ui.editLevel
    if not field then return false end
    local kind = action.kind
    if kind == "cancel" then
        clearEdit(app)
        app.renderer:invalidate("config_table")
        return true
    end

    if kind == "commit" then
        local value = tonumber(app.ui.editBuf or "")
        if value == nil then return false end
        local ok = app.actionHandler and app.actionHandler("config_commit", {
            field = field,
            level = level,
            value = value,
        })
        if ok ~= false then
            clearEdit(app)
            app.renderer:invalidate("config_table")
        end
        return true
    end

    local buf = app.ui.editBuf or ""
    if kind == "digit" then
        if buf == "0" then buf = "" end
        buf = buf .. tostring(action.value or "")
    elseif kind == "mul" or kind == "div" then
        local number = tonumber(buf) or 0
        local scale = tonumber(action.value) or 1
        buf = tostring(kind == "mul" and number * scale or math.floor(number / scale))
    elseif kind == "set" then
        buf = tostring(action.value or "")
    elseif kind == "back" then
        buf = buf:sub(1, math.max(0, #buf - 1))
    elseif kind == "clear" then
        buf = ""
    elseif kind == "copy" then
        local previous = configView(app).rows and configView(app).rows[(level or 1) - 1]
        if previous then buf = tostring(previous.thresholdK or 0) end
    end

    local value = tonumber(buf)
    if value and value > limitFor(field) then return true end
    app.ui.editBuf = buf
    app.renderer:invalidate("config_table")
    return true
end

local function dispatch(app, action)
    if not action then return false end
    if action.type == "page" then
        return app.setPage(action.page)
    elseif action.type == "detail_level" then
        app.ui.detailLevel = action.level
        app.renderer:invalidate("status")
        return true
    elseif action.type == "detail_back" then
        app.ui.detailLevel = nil
        app.renderer:invalidate("status")
        return true
    elseif action.type == "chart_level" then
        app.ui.chartLevel = action.level
        app.renderer:invalidate("chart")
        return true
    elseif action.type == "select_cell" then
        return selectCell(app, action.level, action.field)
    elseif action.type == "select_global" then
        return selectGlobal(app, action.field)
    elseif action.type == "keypad" then
        return applyKeypad(app, action)
    elseif action.type == "produce_page" then
        app.ui.producePage = math.max(1, (app.ui.producePage or 1) + (tonumber(action.delta) or 0))
        app.renderer:invalidate("config_table")
        return true
    elseif action.type == "produce_candidate_page" then
        app.ui.produceCandidatePage = math.max(1,
            (app.ui.produceCandidatePage or 1) + (tonumber(action.delta) or 0))
        app.renderer:invalidate("config_table")
        return true
    elseif action.type == "theme" then
        if app.readOnly then return false end
        local changed = app.setTheme(action.value)
        if changed and app.actionHandler then
            app.actionHandler("theme_set", { value = action.value })
        end
        return changed
    elseif action.type == "option" and app.actionHandler then
        local ok = app.actionHandler(action.name, action)
        if ok ~= false then
            clearEdit(app)
        end
        app.renderer:invalidate("config_table")
        return true
    elseif action.type == "command" and app.actionHandler then
        if app.readOnly and action.name ~= "quit" then return false end
        local ok = app.actionHandler(action.name, action)
        if ok ~= false and action.name == "produce_bind_begin" then
            app.ui.produceCandidatePage = 1
        elseif ok ~= false and action.name == "produce_bind_select" then
            app.ui.produceCandidatePage = 1
        end
        app.renderer:invalidate("config_table")
        return true
    end
    return false
end

--- 把平台输入信号转换为页面切换、编辑或业务动作。
function input.handle(app, signal)
    if not signal then return false end
    local name = signal[1]

    if name == "screen_resized" then
        local width, height = require("component").gpu.getResolution()
        app.layout(width, height)
        return true
    end

    if name == "key_down" then
        local char = signal[3]
        if char == 116 or char == 84 then
            if app.readOnly then return false end
            return app.togglePage()
        elseif char == 120 or char == 88 then
            if app.readOnly then return false end
            if app.actionHandler then app.actionHandler("system_toggle") end
            return true
        elseif char == 114 or char == 82 then
            if app.readOnly then return false end
            if app.actionHandler then app.actionHandler("refresh") end
            return true
        end
        return false
    end

    if name == "touch" then
        return dispatch(app, app.renderer:hit(signal[3], signal[4]))
    end

    return false
end

return input
