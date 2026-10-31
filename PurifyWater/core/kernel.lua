-- 执行内核：每轮最多执行一个步骤。
local kernel = {}

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
