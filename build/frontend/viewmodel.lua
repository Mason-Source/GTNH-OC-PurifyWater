local CONFIG    = require("shared.config")
local computer  = require("computer")
local api       = require("backend.api")
local fstate    = require("frontend.state")
local decorate  = require("frontend.decorate")
local vm        = {}
local cache     = { data = nil, at = 0 }
function vm.build(force)
    local now  = computer.uptime()
    local ttl  = CONFIG.UI.VIEW_REFRESH_SECONDS or 0.25
    local done = cache.data
    if not force and done and (now - cache.at) < ttl then
        return done
    end
    local data = {
        system   = api.read.system(),
        hardware = api.read.hardware(),
        power    = api.read.power(),
        levels   = api.read.levels(),
        net      = api.read.net(),
        host     = api.read.host(),
        logs     = api.read.logs(CONFIG.LOG.MAX_LINES)
    }
    decorate.apply(data)
    if fstate.currentTab == "overview" then
        local days       = (fstate.chartLevel == 0)
            and (CONFIG.CHART.ALL_WINDOW_DAYS or 1) or (CONFIG.CHART.LEVEL_WINDOW_DAYS or 2)
        data.historyDays = days
        data.history     = api.read.history(days * (CONFIG.CHART.SECONDS_PER_GAME_DAY or 86400))
    end
    cache.data, cache.at = data, now
    return data
end
function vm.expire()
    cache.data, cache.at = nil, 0
end
vm.startBlockedReason = decorate.startBlockedReason
return vm
