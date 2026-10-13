--------------------------------------------------------------------------------
-- frontend/viewmodel.lua
--------------------------------------------------------------------------------
-- 【职责】取数（api.read.*）-> 交给 decorate 补成可直接画的形状；带 0.25s 缓存
-- 【不做什么】不画图（panels/charts）、不发命令（input）
-- 【依赖】backend/api、shared/config、frontend/{state,decorate}
-- 【被谁用】frontend/render（每帧取一次）
--
-- 面板不做判定（属后端），这里只把理由翻成一行字并算进度比例。
-- 缓存：默认 0.25 秒重建一次；切页/命令后由 render force 重建；曲线只在总览页算。
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local computer  = require("computer")
local api       = require("backend.api")
local fstate    = require("frontend.state")
local decorate  = require("frontend.decorate")

local vm        = {}

-- 上次构建结果与时刻
---@type { data: table|nil, at: number }
local cache     = { data = nil, at = 0 }

--- 构建视图数据
-- @param force boolean|nil true = 忽略缓存立刻重建
-- @return table
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
        logs     = api.read.logs(CONFIG.LOG.MAX_LINES) -- 内存里就这么多行（盘上那份更全）
    }

    decorate.apply(data)

    -- 曲线只在总览页算；窗口按档位取。
    if fstate.currentTab == "overview" then
        local days       = (fstate.chartLevel == 0)
            and (CONFIG.CHART.ALL_WINDOW_DAYS or 1) or (CONFIG.CHART.LEVEL_WINDOW_DAYS or 2)
        data.historyDays = days
        data.history     = api.read.history(days * (CONFIG.CHART.SECONDS_PER_GAME_DAY or 86400))
    end

    cache.data, cache.at = data, now
    return data
end

--- 视图缓存过期（命令后由 input 调用）
function vm.expire()
    cache.data, cache.at = nil, 0
end

--- 不能启动时的原因（判据只有一处：frontend.decorate；这里留个别名给主端老调用点）
vm.startBlockedReason = decorate.startBlockedReason

return vm
