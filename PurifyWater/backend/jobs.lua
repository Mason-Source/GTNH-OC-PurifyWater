--------------------------------------------------------------------------------
-- backend/jobs.lua
--------------------------------------------------------------------------------
-- 【职责】**定时任务表**：注册所有周期任务，每个任务只做一小步（不许 sleep / 长跑）
-- 【不做什么】不含状态机判断——采集任务只做"读事实 -> 写快照 -> emit 事件"；
--             下发只有 plan.run 一条路（T4 经 system.requestPlan），落盘集中在 store/*（T5）。
-- 【依赖】core/scheduler、shared/*、backend/hardware/*、backend/store/*、backend/debug/memwatch（仅 --debug）
-- 【被谁用】main.lua（启动时调 jobs.register()）
--
-- 任务清单见 ARCHITECTURE.md §3：T1 硬件(10s) / T2 水位(5s) / T3 观测(5s) /
-- T4 调度(5s) / T5 落盘(30s) / T6 内存(1s, --debug) / T7 广播(1s) / T8 制作自动化(1s) / operation runtime(0.5s)；
-- T2s 设置对账只在启动时跑一次（不再周期扫描 settings.txt）。
--------------------------------------------------------------------------------

local computer         = require("computer")
local scheduler        = require("core.scheduler")
local CONFIG           = require("shared.config")
local constants        = require("shared.constants")
local logs             = require("shared.logs")
local state            = require("shared.state")
local utils            = require("shared.utils")

local device           = require("backend.hardware.device")
local machines         = require("backend.hardware.machines")
local probes           = require("backend.hardware.probes")
local energy           = require("backend.hardware.energy")
local fluid            = require("backend.hardware.fluid")

local inventory        = require("backend.store.inventory")
local settings         = require("backend.store.settings")
local levels_config    = require("backend.store.levels_config")
local rates_config     = require("backend.store.rates_config")
local history          = require("backend.store.history")
local log_file         = require("backend.store.log_file")
local system           = require("backend.app.system")
local produceApp       = require("backend.app.produce")
local produceRuntime   = require("backend.app.produce_runtime")

local jobs             = {}

-- 采集摘要（界面/排错用）
local last             = {
    scanCount = 0,
    summary = nil,
    powerBefore = nil,
    meOk = false,
    missing = {},
    fluidOk = false,
    fluidErr = nil
}

-- 本进程启动时刻（require 本模块即启动）
-- 不用 computer.uptime() 当时长：那是机器开机时长，跨程序重启不清零。
local startedAt        = computer.uptime()

-- 内存观测模块句柄（仅 --debug 装载）
local memwatch         = nil

--- 本次运行了多少秒（从 require 本模块算起）
-- @return number
function jobs.elapsed()
    return computer.uptime() - startedAt
end

--- 上次采集摘要
-- @return table
function jobs.last() return last end

-- 内存观测整套在 backend/debug/memwatch，仅 --debug 注册 T6。

--------------------------------------------------------------------------------
-- T1 硬件扫描（10 秒）：机器 + 能量仓 + ME 接口 + 拓扑清单
--------------------------------------------------------------------------------

--- @param skipProducePatrol boolean|nil 启动首轮传 true：先让界面起来，重型侧位扫描留给首个 T1
function jobs.scanHardware(skipProducePatrol)
    device.sweep()
    device.scanMe()
    device.scanNet()
    device.scanMachines()

    local summary = machines.classify()
    -- 制作自动化：已绑件在线检查（只探测已绑地址）+ 重算各级就绪性；就绪性变了就通知调度。
    -- scanSettings() 里的 reload() 发生在 device.scanMachines() 之前，不能用它代替这一轮。
    if produceApp.refresh() then
        scheduler.emit("produce_changed", { reason = "制作自动化就绪性变化" })
    end
    -- 原料巡检（侧位配置 / 原料检查 + 强制开关）；状态变了就通知调度。
    -- 启动首轮刻意跳过：侧位扫描会逐罐逐槽调用组件，不能挡在主界面 boot 前面。
    if skipProducePatrol ~= true and produceApp.patrol() then
        scheduler.emit("produce_changed", { reason = "制作自动化原料状态变化" })
    end
    -- 单仓：取这台仓的功率；无仓 -> 0 进 missing
    local hatch   = machines.energy()
    -- 激光仓电流可调，真值从缓冲容量换算；只认 number，拿不到退回名字值
    local euMax
    if hatch then
        local stored = device.invoke(hatch.address, "getEUMaxStored")
        if type(stored) == "number" then euMax = stored end
    end
    local totalPower, powerNote = energy.powerOf(hatch, euMax)
    if hatch then hatch.power = totalPower end
    local meProxy = device.me()

    local missing = {}
    if summary.host == 0 then missing[#missing + 1] = "净水厂主机" end
    if not meProxy then missing[#missing + 1] = "ME网络接口" end
    if not hatch then missing[#missing + 1] = "能量仓" end

    local diff = inventory.compareAndSave(machines.topology())

    -- 快照
    local prevMissing = last.missing
    last.scanCount          = last.scanCount + 1
    last.summary            = summary
    last.meOk, last.missing = meProxy ~= nil, missing
    -- 缺件边沿（只发快照/日志；事件照旧电平，动作由处理器按"运行中"决定）
    if #prevMissing > 0 and #missing == 0 then
        logs.system("硬件缺失已恢复：" .. table.concat(prevMissing, "、") .. "；点【启动系统】恢复")
    elseif #prevMissing == 0 and #missing > 0 then
        logs.warn("硬件缺失：" .. table.concat(missing, "、") .. "；请补齐缺失硬件")
    end
    -- 功率是"建议并行"的输入之一：折算最大值落 state（可用 = 最大 × 利用因子，读时现算）
    local prevAll = state.read.powerAll()
    if state.read.powerMax() ~= totalPower then
        state.write.setPowerMax(totalPower)
    end

    -- 事件（顺序 = 归因优先级：缺件 / 变更在前，功率在后）
    if #missing > 0 then
        scheduler.emit("hardware_missing", { missing = missing })
    end
    if diff.changed then
        scheduler.emit("hardware_changed", diff)
    end
    local nowAll = state.read.powerAll()
    if prevAll ~= nowAll then
        scheduler.emit("power_changed", { from = prevAll, to = nowAll, note = powerNote })
    end
    last.powerBefore = totalPower

    logs.debug(string.format("硬件扫描 #%d：主机 %d、单元 %d、能量仓 %s、网卡 %s、其它 %d、总功率 %s、缺失 %s",
        last.scanCount, summary.host, summary.unitTotal, hatch and hatch.name or "无",
        device.net() and "有" or "无", summary.other,
        utils.formatNumber(totalPower), (#missing > 0 and table.concat(missing, "/") or "无")))
end

--------------------------------------------------------------------------------
-- T2s 设置对账（**仅启动一次**）：一次读全 settings.txt，交给各配置模块比对；
--   谁的内容变了就发谁的事件（阈值/勾选 -> level_rules_changed；权重/T7 倍率 -> rates_changed）。
-- 运行中改配置走命令层（直改内存 + 落盘，即时生效）；手改文件 = 重启后生效。
-- 新增可手改配置在此多调一次 load(snapshot) 即可。
--------------------------------------------------------------------------------

function jobs.scanSettings()
    local snapshot = settings.load() or {}

    local changed, why = levels_config.load(snapshot)
    if changed then
        scheduler.emit("level_rules_changed", { why = why })
    end

    local ratesChanged, ratesWhy = rates_config.load(snapshot)
    if ratesChanged then
        scheduler.emit("rates_changed", { why = ratesWhy })
    end

    local produceChanged, produceWhy = produceApp.reload(snapshot)
    if produceChanged then
        scheduler.emit("produce_changed", { reason = produceWhy })
    end
end

--------------------------------------------------------------------------------
-- T2 水位读取（5 秒）：1-8 级
--------------------------------------------------------------------------------

function jobs.readFluids()
    local amounts, ok, err = fluid.readAll()
    last.fluidOk, last.fluidErr = ok, err

    -- 【读不到按 0】网络里暂时还没水缓存是**正常态**，不是故障：按 0 判定的结果天然是
    --   "只强开源头那一级（T1）、L2-T8 被原料线挡住"——已经是安全退化，不必停机，也不必进入等待。
    --   长期取 0 而网络里有水，界面会体现；ok/err 只留调试（退出摘要）。
    -- 【没有下游事件】水位只是快照里的一个数：调度每拍（T4）本来就会用最新水位现算可开启性。
    local fluids = {}
    for level = 1, constants.LEVEL_COUNT do
        fluids[level] = (ok and amounts[level]) or 0
    end
    state.write.setFluids(fluids)
end

--------------------------------------------------------------------------------
-- T3 开关与运行状态（5 秒）：T0-8
-- 【只报事实】每级一行 `plant_observed`（开关/在跑台数 + **读这一刻该级的方案**）
--   + 在跑的每台一条 `parallel_sample`。
--   "开关变了没有"（边沿）、"偏离方案没有"（判定）、"该不该警告"（后果）
--   全部在 backend/app/watch.lua —— 这里只管读，不管判断。
--   方案值必须随事实走：判断层不许自己另取（读数与判定之间可能刚下发过新方案）。
--------------------------------------------------------------------------------


function jobs.observePlants()
    local samples, runningTotal = 0, 0

    -- 【主机停机 -> 不读机器配置】主机是总开关：它关着的时候单元的进度/传感器既无意义也不会变，
    --   跳过它们能省下一半以上的组件调用。开关（switch/active）照读：既要上屏，
    --   也是判断"主机重新开机"的唯一依据。值在 level 0 那一轮读完后填上（主机最先读）。
    local hostAllowed = nil
    -- 【运行周期进度只读主机（T0）】各水厂周期同步，逐台读 getWorkProgress/getWorkMaxProgress
    --   是每轮 2×机器数 次白费调用；主机自己报这个数，读一次够用。它只有两个去处：
    --   进主机快照（界面周期条）与交给 tracker 判周期边界 —— T1-8 不记进度。
    local hostProgress, hostProgressMax
    -- 【发布粒度】台数变了几级都只算"这一轮变过"：整轮观测结束后统一发一条事实，
    --   避免逐级发事件（循环中途 top 逐级增长，会连打出 T1-3→T1-8 那种一串）
    local deployedLevels = {}

    for level = constants.HOST_LEVEL, constants.LEVEL_COUNT do
        local list                 = machines.of(level)
        local snap                 = state.read.plant(level)
        -- 【对照基准随事实走】读这一刻该级的方案是什么（可为 nil：停机 / 还没跑过 / 上一轮没发出去）。
        --   判定层要拿它对照这条读数；判定若自己另取方案，就会拿"读数之后才下发的新方案"去比旧读数。
        local want                 = state.read.lastPlan()[level]

        local total, on, off, fail = 0, 0, 0, 0
        local running, actFail     = 0, 0
        local facts                = {} -- 每台的**原始读数**（不做任何加工，界面直接用）
        -- 本级汇总：多台机器时只留**最低并行 / 最小成功率**（最保守的那个数），界面上不加字说明
        local minSample, minSuccess

        for _, machine in ipairs(list) do
            total     = total + 1
            local sw  = probes.switch(machine.address)
            local act = probes.active(machine.address)
            -- 进度只在主机这一轮读；主机开关关着时不用读（进度不会变，读了也没意义）
            if level == constants.HOST_LEVEL and sw ~= false then
                hostProgress, hostProgressMax = probes.progress(machine.address)
                -- 制作自动化：周期边界检测（复用这次全局周期读数；只做边沿判定）
                produceApp.onCycleProgress(hostProgress, hostProgressMax)
            end
            -- 逐台原始读数（后面读传感器时还会往里补 success）
            local fact = { address = machine.address, switch = sw, active = act }

            if sw == true then
                on = on + 1
            elseif sw == false then
                off = off + 1
            else
                fail = fail + 1
            end
            if act == true then running = running + 1 end
            if act == nil then actFail = actFail + 1 end

            facts[#facts + 1] = fact

            -- 【只对“主机允许 + 正在运行”的单元读传感器】停机时 parallel.current 报 1，没有意义
            if level >= 1 and act == true and hostAllowed ~= false then
                local info  = probes.sensor(machine.address)
                local value = info and info.parallel
                if type(value) == "number" then
                    local success = info and info.success or nil
                    -- 【逐台也记一份】（详情页要"每台机器分别的当前并行 / 成功率"；停机后保留最后一次）
                    fact.parallel = value
                    fact.success  = success
                    if not minSample or value < minSample then minSample = value end
                    if success and (not minSuccess or success < minSuccess) then minSuccess = success end
                    samples = samples + 1
                    -- seq 一起带上：tracker 按 produce 周期钟确认并行（周期号变化 = 新周期）
                    scheduler.emit("parallel_sample", {
                        level    = level,
                        address  = machine.address,
                        parallel = value,
                        success  = success,
                        seq      = state.read.produce().cycle.seq
                    })
                end
            end
        end

        -- 读取失败与"确实是关"必须分开；任何一台读取失败 -> nil（未知），不当成关。
        local observed = nil
        if total > 0 and fail == 0 then
            if on == total then
                observed = true
            elseif off == total then
                observed = false
            end
        end

        -- 台数是"建议并行"的另一个输入：这里只记"这一轮变过"，整轮跑完再统一发事实
        local deployed = snap.deployed or 0
        if deployed ~= total then
            deployed = total
            deployedLevels[#deployedLevels + 1] = level
        end
        local fields = {
            deployed = deployed,
            switch   = observed,
            active   = (total > 0 and actFail == 0) and running or nil,
            machines = facts -- 逐台原始读数（详情页直接用）
        }
        -- 本轮没读到就不动旧值（停机后保留最后一次，界面会标"(上次)"）
        if minSample then fields.sample = minSample end
        if minSuccess then fields.success = minSuccess end
        if level == constants.HOST_LEVEL then
            -- 运行周期只挂在主机（T0）这一行：api.read.host 从这里取周期条数据
            fields.progress    = hostProgress
            fields.progressMax = hostProgressMax
        end
        state.write.recordPlant(level, fields)
        runningTotal = runningTotal + running

        if level == constants.HOST_LEVEL then
            -- 主机的总开关决定后面几级要不要读“机器配置”（见函数开头说明）
            hostAllowed = observed
        end

        -- 【事实出口 1】每级一行观测（含主机 level=0）：边沿/判定/警告由 app/watch 决定；
        --   want = 读这一刻该级的方案（偏离判定就靠它，见 app/watch）
        if total > 0 then
            scheduler.emit("plant_observed", {
                level = level, switch = observed, active = snap.active, deployed = total, want = want
            })
        end
    end

    -- 一轮观测结束：台数变过才发事实（每轮最多一条；发布由事件处理器做）
    if #deployedLevels > 0 then
        scheduler.emit("deployed_changed", { levels = deployedLevels })
    end

    logs.debug(string.format("观测：单元在跑 %d 台，本轮采样 %d 条", runningTotal, samples))
end

--------------------------------------------------------------------------------
-- T4 定时调度（5 秒）：按各等级可开启情况 + 功率预算，做一轮贪心调度
-- 定时任务与事件驱动互补：事件负责"条件一变立刻反应"，这个周期任务负责兜底那些
--   "没有事件、只能现算"的输入（水位 / 阈值 / 优先级变化后，下一轮重新纳入调度）。
-- 注意：它不"纠正"人工改动——实测偏离方案由 T3→watch 停会话、等待用户（不动机器）。
--------------------------------------------------------------------------------

function jobs.schedule()
    system.requestPlan("定时")
end

--------------------------------------------------------------------------------
-- T5 落盘（30 秒）：抽一个曲线点，然后写盘
-- 抽点放在这里：曲线 30 秒一个点就够，与落盘同节奏就不必两个计时器。
-- 历史每拍全量重写（80 点小文件）；日志只在新行时写、环形保留（见 store/{history,log_file}）。
-- 盘是最慢的东西（机械硬盘 + OC 沙箱）——日志没有新行就一次盘都不碰。
--------------------------------------------------------------------------------

function jobs.persist()
    if memwatch then memwatch.watch(jobs.elapsed()) end -- 退出/落盘前看一眼余量（仅 --debug）
    history.append()

    local ok, text = history.save()
    if not ok then logs.debug("T5 写历史失败：" .. tostring(text)) end

    -- 日志：把内存里还没落盘的新行追加进 data/log.txt（没有新行就一次盘都不碰）
    local okLog, logNote = log_file.flush()
    if not okLog then logs.debug("T5 写日志失败：" .. tostring(logNote)) end
end

--------------------------------------------------------------------------------
-- 注册
--------------------------------------------------------------------------------

--- 注册全部定时任务（重复调用安全：同名任务会被 scheduler 拒绝）
-- @return number 成功注册的任务数
function jobs.register()
    local n = 0
    local function add(...)
        if scheduler.every(...) then n = n + 1 end
    end

    add("scanHardware", CONFIG.INTERVAL.HARDWARE, jobs.scanHardware)  -- T1
    add("readFluids", CONFIG.INTERVAL.FLUID, jobs.readFluids)         -- T2
    add("observePlants", CONFIG.INTERVAL.OBSERVE, jobs.observePlants) -- T3
    add("schedule", CONFIG.INTERVAL.SCHEDULE, jobs.schedule)          -- T4
    add("persist", CONFIG.INTERVAL.PERSIST, jobs.persist)             -- T5
    add("produce", CONFIG.INTERVAL.PRODUCE, produceApp.tick)          -- T8
    add("produce_runtime", CONFIG.INTERVAL.PRODUCE_RUNTIME, produceRuntime.tick) -- 制作自动化 operation 调度
    -- T6 内存观测：仅 --debug 装模块、注册任务。
    if logs.isDebug() then
        memwatch = require("backend.debug.memwatch")
        add("sampleMemory", CONFIG.INTERVAL.SAMPLE, memwatch.sample) -- T6
    end
    -- T7 广播在 main.lua 注册（它需要 api 提供的快照来源，放这里会环依赖）

    -- 首次采集不必等 10 秒：注册后立刻各跑一次，屏幕马上有数据
    -- T2s 设置对账也只在这一次跑（之后不再周期扫描 settings.txt）
    jobs.scanSettings()
    jobs.scanHardware(true) -- 首轮只做轻量扫描；T1 下一轮再配置侧位
    jobs.readFluids()
    jobs.observePlants()
    return n
end

return jobs
