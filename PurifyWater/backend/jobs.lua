--------------------------------------------------------------------------------
-- backend/jobs.lua
--------------------------------------------------------------------------------
-- 【职责】**定时任务表**：注册所有周期任务，每个任务只做一小步（不许 sleep / 长跑）
-- 【不做什么】不含动作（改状态/下发/写盘由 backend/app/* 的事件处理器做）——
--             任务体只做"采集事实 -> 写快照 -> emit 事件"
-- 【依赖】core/scheduler、shared/*、backend/hardware/*、backend/store/*、backend/debug/memwatch（仅 --debug）
-- 【被谁用】main.lua（启动时调 jobs.register()）
--
-- 【任务清单（ARCHITECTURE.md §3）】
--   T1 scanHardware  10 s  硬件 + 功率 + 拓扑清单         -> hardware_missing / hardware_changed / power_changed
--   T2 readFluids     5 s  1-8 级水量 + 阈值文件变更       -> fluid_state / level_rules_changed（**读不到按 0**）
--   T3 observePlants  5 s  T0-8 开关与活动；在运行的读传感器
--                                                       -> plant_observed ×N / parallel_sample ×N
--                                                       （边沿、归因、不一致判定在 app/watch）
--   T4 schedule       5 s  跑一轮调度（算方案 -> 下发）   -> 由 app/plan 具体干活
--   T5 persist       30 s  抽一个曲线点 + 脏数据落盘（含日志，不脏就不写盘）
--   T6 sampleMemory   1 s  **仅 --debug**：内存地板/峰值采样（整套观测在 backend/debug/memwatch）
--   T7 broadcast      1 s  无线快照（门控：总开关 + 网卡在位；在 main.lua 注册）
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
local levels_config    = require("backend.store.levels_config")
local records          = require("backend.store.records")
local history          = require("backend.store.history")
local log_file         = require("backend.store.log_file")
local power            = require("backend.domain.power")
local plan             = require("backend.app.plan")

local jobs             = {}

-- 采集摘要（界面 / 排错用；不含业务判断）
local last             = {
    scanCount = 0,
    summary = nil,
    powerBefore = nil,
    meOk = false,
    missing = {},
    fluidOk = false,
    fluidErr = nil
}

-- 上次告过的"实测 ≠ 建议"（文本一变就再告一次；不变就不刷屏）
local lastParallelWarn = nil

-- 本进程启动时刻（本模块被 require 时就是程序启动；main/monitor 开头就 require 它）
-- 【为何不用 computer.uptime() 当运行时长】它返回的是**机器开机**时长，跨程序重启不清零，
--   拿它当"本次运行 N 秒"会得到自相矛盾的数字（实测三次退出的比例对不上就是这个原因）。
local startedAt        = computer.uptime()

-- 内存观测模块句柄：**只在 --debug 下**在 jobs.register 里装上（整套观测见 backend/debug/memwatch）
local memwatch         = nil

--- 本次运行了多少秒（从 require 本模块算起）
-- @return number
function jobs.elapsed()
    return computer.uptime() - startedAt
end

--- 上次采集摘要
-- @return table
function jobs.last() return last end

-- 【内存观测（地板/峰值/告警/留痕）不在这里】它是诊断用的"测试内容"（决策 32）：整套在
--   `backend/debug/memwatch.lua`，**只在 --debug 下才装、才注册 T6**（见 jobs.register）。

--------------------------------------------------------------------------------
-- T1 硬件扫描（10 秒）：机器 + 能量仓 + ME 接口 + 拓扑清单
--------------------------------------------------------------------------------

function jobs.scanHardware()
    -- 组件缓存先失效：插拔后 component.list 才是权威（这一步也顺带重取 ME 代理）
    device.invalidate()

    local summary = machines.scan()
    -- 单仓：功率就取这一台仓的（没有仓 -> 0，会进 missing）
    local hatch   = machines.energy()
    -- 激光仓的电流能在仓界面里调小 -> 名字只给上限，真值要从缓冲容量换算（见 hardware/energy）。
    -- 不先判名字：非激光仓读了也会被 powerOf 忽略，一次 invoke 而已
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

    local diff              = inventory.compareAndSave(machines.topology())

    -- 快照
    last.scanCount          = last.scanCount + 1
    last.summary            = summary
    last.meOk, last.missing = meProxy ~= nil, missing
    state.power.all         = totalPower

    -- 【当前并行 vs 建议并行】有任一等级不一致就写一行警告。
    --   当前并行 = snap.sample（本周期读到、**未确认**）；真实并行 = snap.parallel（连续 N 周期确认），
    --   它属"记录是否过时"那条线，不在这里比。
    --   边沿触发：两个数通常长期稳定，每 10 秒刷一屏只会挤掉别的行。
    --   不自作结论：可能机器没吃满、可能建议值被上限夹住、也可能刚换能源仓在过渡。
    local warnParts         = {}
    for _, item in ipairs(power.parallelMismatch()) do
        warnParts[#warnParts + 1] = string.format("%s 当前 %s / 建议 %s", constants.levelLabel(item.level),
            utils.formatShortNumber(item.current), utils.formatShortNumber(item.suggest))
    end
    local warnText = table.concat(warnParts, "；")
    if warnText ~= lastParallelWarn then
        lastParallelWarn = warnText
        if warnText ~= "" then
            logs.warn("当前并行与建议并行不一致：" .. warnText)
        end
    end

    -- 事件
    if #missing > 0 then
        scheduler.emit("hardware_missing", { missing = missing })
    end
    if diff.changed then
        scheduler.emit("hardware_changed", diff)
    end
    if last.powerBefore ~= nil and math.floor(last.powerBefore) ~= math.floor(totalPower) then
        scheduler.emit("power_changed", { from = last.powerBefore, to = totalPower, note = powerNote })
    end
    last.powerBefore = totalPower

    logs.debug(string.format("[调试] 硬件扫描 #%d：主机 %d、单元 %d、能量仓 %s、其它 %d、总功率 %s、缺失 %s",
        last.scanCount, summary.host, summary.unitTotal, hatch and hatch.name or "无", summary.other,
        utils.formatNumber(totalPower), (#missing > 0 and table.concat(missing, "/") or "无")))
end

--------------------------------------------------------------------------------
-- T2 水位读取（5 秒）：1-8 级 + 阈值文件变更检测
--------------------------------------------------------------------------------

function jobs.readFluids()
    -- 阈值文件变更检测（用户可能刚在电脑上改过）：变了就广播，让调度立刻按新阈值来
    local changed, why = levels_config.load()
    if changed then
        scheduler.emit("level_rules_changed", { why = why })
    end

    local amounts, ok, err = fluid.readAll()
    last.fluidOk, last.fluidErr = ok, err

    -- 【读不到按 0】网络里暂时还没水缓存是**正常态**，不是故障：按 0 判定的结果天然是
    --   "只强开源头那一级（T1）、L2-T8 被原料线挡住"——已经是安全退化，不必停机、更不必锁定。
    --   长期取 0 而网络里有水，用户看水量列/曲线会自己察觉。ok/err 只留作排查（退出摘要那行）。
    for level = 1, constants.LEVEL_COUNT do
        local amount = (ok and amounts[level]) or 0
        state.fluids[level] = amount
        scheduler.emit("fluid_state", { level = level, amount = amount })
    end
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

    for level = constants.HOST_LEVEL, constants.LEVEL_COUNT do
        local list                 = machines.of(level)
        local snap                 = state.plant(level)
        -- 【对照基准随事实走】读这一刻该级的方案是什么（可为 nil：停机 / 还没跑过 / 上一轮没发出去）。
        --   判定层要拿它对照这条读数；判定若自己另取方案，就会拿"读数之后才下发的新方案"去比旧读数。
        local want                 = state.lastPlan[level]

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
                    -- progress 一起带上：tracker 按“运行周期”确认并行（进度回落 = 新周期）
                    scheduler.emit("parallel_sample", {
                        level    = level,
                        address  = machine.address,
                        parallel = value,
                        success  = success,
                        progress = hostProgress
                    })
                end
            end
        end

        -- 【关键】"读不到"与"确实是关"必须分开：
        --   任何一台读不到 -> nil（未知，界面显示 ?），**绝不当成"关"**。
        --   v2 踩过同类坑：代理失效时把"开着"显示成"关闭"，排查半天。
        local observed = nil
        if total > 0 and fail == 0 then
            if on == total then
                observed = true
            elseif off == total then
                observed = false
            end
        end

        snap.deployed = total
        snap.switch   = observed
        snap.active   = (total > 0 and actFail == 0) and running or nil
        snap.machines = facts -- 逐台原始读数（详情页直接用）
        -- 本轮没读到就不动旧值（停机后保留最后一次，界面会标"(上次)"）
        if minSample then snap.sample = minSample end
        if minSuccess then snap.success = minSuccess end
        runningTotal = runningTotal + running

        if level == constants.HOST_LEVEL then
            -- 运行周期只挂在主机（T0）这一行：api.read.host 从这里取周期条数据
            snap.progress    = hostProgress
            snap.progressMax = hostProgressMax
            -- 主机的总开关决定后面几级要不要读“机器配置”（见函数开头说明）
            hostAllowed      = snap.switch
        end

        -- 【事实出口 1】每级一行观测（含主机 level=0）：边沿/判定/警告由 app/watch 决定；
        --   want = 读这一刻该级的方案（偏离判定就靠它，见 app/watch）
        if total > 0 then
            scheduler.emit("plant_observed", {
                level = level, switch = observed, active = snap.active, deployed = total, want = want
            })
        end
    end

    logs.debug(string.format("[调试] 观测：单元在跑 %d 台，本轮采样 %d 条", runningTotal, samples))
end

--------------------------------------------------------------------------------
-- T4 定时调度（5 秒）：按各等级可开启情况 + 功率预算，做一轮贪心调度
-- 定时任务与事件驱动互补：事件负责"条件一变立刻反应"，这个周期任务负责
--   "没人触发也要周期性对齐"（例如玩家直接在 GT 界面把机器关了，下一轮就会纠正回来）。
--------------------------------------------------------------------------------

function jobs.schedule()
    -- 没在跑/已锁定：连"尝试调度"都不发起（plan.run 里那道闸是最后一道保险）
    if state.isActive() then plan.run("定时") end
end

--------------------------------------------------------------------------------
--- T5 落盘（30 秒）：抽一个曲线点，然后只在"脏"时写盘
-- 抽点放在这里：曲线 30 秒一个点就够，与落盘同节奏就不必两个计时器。
-- 日志也在这里收：内存只留屏幕上放得下的几行，新行攒到这一拍一起追加（见 store/log_file）。
-- 【不脏不写】盘是游戏里最慢的东西（机械硬盘 + OC 沙箱），没事别碰。
--------------------------------------------------------------------------------

function jobs.persist()
    if memwatch then memwatch.watch(jobs.elapsed()) end -- 退出/落盘前看一眼余量（仅 --debug）
    history.append()
    state.markDirty("history")

    if state.isDirty("records") then
        local ok, text = records.save(nil)
        logs.debug("[调试] T5 写并行记录：" .. tostring(text))
        if ok then state.clearDirty("records") end
    end
    if state.isDirty("levels") then
        levels_config.saveAll()
        state.clearDirty("levels")
    end
    local ok, text = history.save()
    if not ok then logs.debug("[调试] T5 写历史失败：" .. tostring(text)) end

    -- 日志：把内存里还没落盘的新行追加进 data/log.txt（没有新行就一次盘都不碰）
    local okLog, logNote = log_file.flush()
    if not okLog then logs.debug("[调试] T5 写日志失败：" .. tostring(logNote)) end
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
    -- T6 内存观测：**只在 --debug 下装模块、注册任务**（日常运行连模块都不 require，见决策 32）
    if logs.isDebug() then
        memwatch = require("backend.debug.memwatch")
        add("sampleMemory", CONFIG.INTERVAL.SAMPLE, memwatch.sample) -- T6
    end
    -- T7 广播在 main.lua 注册（它需要 api 提供的快照来源，放这里会环依赖）

    -- 首次采集不必等 10 秒：注册后立刻各跑一次，屏幕马上有数据
    jobs.scanHardware()
    jobs.readFluids()
    jobs.observePlants()
    return n
end

return jobs
