--------------------------------------------------------------------------------
-- PurifyWater/core/kernel.lua
--
-- 定位：最小事件循环内核。
-- 功能：每轮等待至多一个事件或截止时间，然后最多推进一个业务步骤。
-- 边界：不解释事件内容，不依赖具体服务；所有策略由调用方通过环境表注入。
--------------------------------------------------------------------------------

local kernel = {}

--- 运行单步事件循环，直到环境表报告退出。
function kernel.run(env)
    while not env.quit() do
        local now = env.clock()
        local delay = math.max(0, env.nextDue(now) - now)
        local signal = env.wait(delay)
        if signal then env.input(signal) end
        env.step(env.clock())
    end
end

return kernel
