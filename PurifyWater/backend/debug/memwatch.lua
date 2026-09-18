--------------------------------------------------------------------------------
-- backend/debug/memwatch.lua
--------------------------------------------------------------------------------
-- 【职责】内存观测：地板/峰值采样、刷新新低时告警、痕迹留痕、退出摘要里那一小段文字
-- 【不做什么】不碰业务：不读机器、不改状态、不写业务数据、不进界面与调度
-- 【依赖】computer、shared/logs、backend/store/trace
-- 【被谁用】main.lua / backend/jobs（**都只在 --debug 下才 require 它**）
--
-- 【为什么单独一个文件】这套东西是诊断用的"测试内容"，不属于业务（决策 32）：日常运行（不带 --debug）
--   连这个模块都不装、一个数都不采 —— 业务文件里也就看不到它。
--------------------------------------------------------------------------------

local computer          = require("computer")
local logs              = require("shared.logs")
local trace             = require("backend.store.trace")

local memwatch          = {}

-- 本次运行见过的最低"可用"（地板，K）与最高"占用"（峰值，K）
-- 【峰值 = 总 − 地板】总（`totalMemory`，内存条给的上限）在运行期固定，所以"可用"最低的那一刻
--   就是"占用"最高的那一刻 —— 不必单独再记一个最大值。
local memFloor, memPeak = nil, nil
-- 上次报过的地板（只在新低时提醒）
local memFloorWarned    = nil
-- 上次往痕迹里写内存行的时刻（10 分钟一行，不刷盘）
local memTraceAt        = 0

--- 采一次内存，刷新"地板"与"峰值"（**零垃圾**：不写日志、不拼字符串，每秒都会被调）
-- 【地板 = 本次运行见过的最低"可用"】单次采样看不出趋势：Lua 的堆会顶到活数据约两倍才回收
--   （这个参数 OC 里改不了），所以"可用"在几十 K 到几百 K 之间来回摆。
--   健康的样子是地板**停在一个数上不下来**；地板一直往下走才是真的要崩。
-- @return number 本次"可用"（K）
-- @return number 本次"可用"（字节）
-- @return number 总（字节）
local function note()
    local free   = computer.freeMemory() or 0
    local total  = computer.totalMemory() or 0
    local floorK = math.floor(free / 1024)
    if not memFloor or floorK < memFloor then memFloor = floorK end
    memPeak = math.floor(total / 1024) - memFloor
    return floorK, free, total
end

--- T6 内存峰值采样（1 秒）：只更新"地板 / 峰值"两个数
-- 【为什么值得单开一拍】T5 是 30 秒一采，而**最占内存的瞬间是界面重画**（每个点一个表 +
--   整屏 `gpu.set`），只持续几十毫秒 —— 30 秒一采大概率错过真正的峰值，量出来的"峰值"会偏小。
--   这里只做两个整数比较（不建字符串 = 不造垃圾），主循环本来就睡不到 1 秒以上，等于白捡。
function memwatch.sample()
    note()
end

--- 看护（T5 开头与退出前各跑一次）：刷地板/峰值、刷新新低时提醒、每 10 分钟留一行痕迹
-- 【为何只能"看"不能"收"】OC 的沙箱里 `collectgarbage` 是 nil（实机报过
--   `attempt to call a nil value (global 'collectgarbage')`）：回收参数改不了，也不能主动收。
--   内存只有两条路 —— **少造垃圾**（视图缓存、别每帧重建）与**少留数据**（只留屏幕上放得下的）；
--   回收本身靠主循环每帧 `event.pull` 让出时 GC 自己跑。
-- 【读什么】可用 / 地板 / 峰值 / 总（`totalMemory` 就是内存条给的上限）。实机 1024K 下的典型形状：
--   地板 20~40K 稳住 = 健康（GC 能跑完自己的回合）；地板一路往下（142K→89K→19K）= 要崩。
-- @param elapsed number|nil 本次已跑多少秒（**由调用方给**：`jobs.elapsed()` 是唯一口径，
--                这里不再自己记启动时刻）
function memwatch.watch(elapsed)
    local floorK, _, total = note()

    logs.debug(string.format("[调试] 内存：可用 %dK / 地板 %dK / 峰值 %dK / 总 %dK",
        floorK, memFloor, memPeak, math.floor(total / 1024)))

    -- 【告警：只在"刷新新低"时喊】按百分比喊会一直叫（低位本来就在几十 K 摆，不是危险信号）。
    --   每降 16K 报一次，且仅当低于总量 6% 时才报（1024K 机器上即 <61K）。
    --   判据用**地板**而不是本次采样：最低点是 T6 每秒采出来的，本行（30 秒一拍）可能正好采在高处。
    if total > 0 and memFloor * 1024 < total * 0.06 then
        if not memFloorWarned or memFloor <= memFloorWarned - 16 then
            memFloorWarned = memFloor
            logs.warn(string.format("内存新低：可用 %dK / 总 %dK —— 低位在往下走，离崩不远",
                memFloor, math.floor(total / 1024)))
        end
    end

    -- 【留痕】崩溃不走退出路径（崩溃现场在 last_run.txt 里可能只有一行"启动"），
    --   所以地板低时每 10 分钟往痕迹里写一行（**带峰值**）；跑 --debug 时不管紧不紧，一路记趋势。
    --   带"本次已跑 N 分"：崩溃前最后写下的那一行就是崩溃时刻（±10 分钟）。
    local now = computer.uptime()
    if (memFloor * 1024 < total * 0.3) or logs.isDebug() then
        if (now - memTraceAt) > 600 then
            memTraceAt = now
            trace.line(string.format("内存：峰值 %dK / 总 %dK（地板 %dK），本次已跑 %d 分",
                memPeak, math.floor(total / 1024), memFloor,
                math.floor((elapsed or 0) / 60)))
        end
    end
end

--- 写启动那两行痕迹（读数由调用方在**任何本工程模块之前**取好，见 main.lua）
-- @param bootFree number 引导阶段的"可用"（字节）
-- @param bootTotal number 引导阶段的"总"（字节）
function memwatch.traceBoot(bootFree, bootTotal)
    trace.line(string.format("内存基线：可用 %dK / 总 %dK（此刻只装了引导模块，差额就是 OpenOS shell）",
        math.floor((bootFree or 0) / 1024), math.floor((bootTotal or 0) / 1024)))

    -- 【装载后读数】此刻本工程 55 个模块的字节码才全在堆上。
    -- 【别把它当"模块大小"读】Lua 的回收是**攒够才跑**（堆能涨到活数据两倍），所以这一读里还混着
    --   加载过程造出的垃圾 —— 实机同一份代码两次启动分别读到 `1273K` 与 `661K`，差额被垃圾主宰。
    --   真正能用的是另外两个数："基线"（OpenOS 的地盘）与运行中的 `可用 / 峰值 / 地板`。
    local free  = computer.freeMemory() or 0
    local total = computer.totalMemory() or 0
    trace.line(string.format("内存装载后：可用 %dK / 总 %dK（含加载垃圾，比实际占用偏大）",
        math.floor(free / 1024), math.floor(total / 1024)))
end

--- 退出摘要里的内存那一小段（没采过就返回 nil，调用方据此不加这段）
-- @return string|nil 例如 `峰值 1892K / 总 2048K（可用 156K / 地板 156K）`
function memwatch.summary()
    if not memPeak then return nil end
    return string.format("峰值 %dK / 总 %dK（可用 %dK / 地板 %dK）",
        memPeak, math.floor((computer.totalMemory() or 0) / 1024),
        math.floor((computer.freeMemory() or 0) / 1024), memFloor)
end

return memwatch
