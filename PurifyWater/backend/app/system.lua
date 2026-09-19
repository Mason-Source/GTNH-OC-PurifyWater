--------------------------------------------------------------------------------
-- backend/app/system.lua
--------------------------------------------------------------------------------
-- 【职责】系统级状态机与停机安全：启动 / 停机 / 进安全状态（锁定）/ 主机开关对齐
-- 【依赖】domain/{actuator,tracker}、store/records、app/plan、shared/{config,constants,logs,state}
-- 【被谁用】backend/handlers.lua（事件接线）、app/watch（观测对齐与归因）、main（临时按键）
--
-- 【状态】
--   state.system.running    系统是否在自动调度
--   state.system.locked     锁定：出过需要人来处理的事，**不自动恢复**（等用户点【启动系统】）
--   state.system.lockReason 锁定原因（**只记第一条**：谁先出事谁是真因，后来的事件不顶掉它）
--
-- 【没有自动恢复】恢复调度的**唯一**入口是用户点【启动系统】；早期那几套自动恢复
--   （开关一致 N 次、主机重开、水位读得到）已全部删除。
--
-- 【两类锁定只有这一个入口】`enterSafeState(why, allOff, line)`，区别只在 allOff：
--   A. 用户开关 T0 / 硬件缺失 / 硬件变更 -> 下发一次全关 + 锁定（控制对象变了，先关掉才安全）
--   B. T1-8 开关被人工改动 -> 不动机器 + 锁定（只管停调度、机器保持现状）
--   **幂等与"只报一次"都在 enterSafeState 里**（`locked` 早退吞掉重复进入；传进去的 `line`
--   只在真的进锁那一刻写），所以各触发器都只是"拼锁因 + 一行说明"，不持有去重标志。
--   锁定期保留只读逻辑（T1/T2/T3 采集、界面、日志），调度入口一律被 state.isActive() 拦下。
-- 【主机开关关】算 A 类；主机重新打开后同样要用户手动点【启动系统】。
--------------------------------------------------------------------------------

local CONFIG          = require("shared.config")
local constants       = require("shared.constants")
local logs            = require("shared.logs")
local state           = require("shared.state")
local computer        = require("computer")

local actuator        = require("backend.domain.actuator")
local tracker         = require("backend.domain.tracker")
local records         = require("backend.store.records")
local plan            = require("backend.app.plan")

-- 主机总开关被关时用的锁定原因（**只写一处**：启动拒绝、边沿处理、观测对齐都引它）
local HOST_OFF_REASON = "主机开关已关"

local system          = {}

--- 启动（开始自动调度；**锁定后唯一的手动恢复入口**）
-- 主机停机时不允许启动：关着的时候启动调度没有意义（下一轮就会被主机对齐打断）；
--   这里直接拒绝 + 进安全状态，界面按钮也是灰的。
-- @param reason string
-- @return boolean 是否真的启动了
function system.start(reason)
    if state.plant(constants.HOST_LEVEL).switch == false then
        system.ensureHostStoppedLock()
        logs.warn("无法启动：净水主机开关是关的（请先在主机上打开）")
        return false
    end
    -- 手动重新启用调度：锁定在这里解除（日志里会写明原锁定原因，方便对账）
    if state.system.locked then system.unlock() end
    state.system.running = true
    logs.system(string.format("启动（%s）", tostring(reason or "-")))
    plan.forget()
    plan.run("启动")
    return true
end

--- 停机（下发全关）
-- 停机统一走它（机器必须真被关掉）；进安全状态（A 类）也复用这一条。
-- @param reason string
function system.stop(reason)
    local count = actuator.shutdownAll()
    state.system.running = false
    plan.forget()
    logs.system(string.format("停机（%s）：已下发全关 %d 台", tostring(reason or "-"), count))
end

--- 锁定（不再自动恢复，直到解锁）
-- @param why string
function system.lock(why)
    state.system.locked     = true
    state.system.lockReason = tostring(why or "锁定")
    logs.warn("已锁定：" .. state.system.lockReason)
end

--- 解锁
-- 唯一调用者是 system.start（用户点【启动系统】）；锁定是状态，不是待办队列。
-- @return boolean 是否真的解锁了
function system.unlock()
    if not state.system.locked then return false end
    local why = state.system.lockReason
    state.system.locked, state.system.lockReason = false, nil
    logs.system("已解锁（原锁定原因：" .. tostring(why) .. "）")
    return true
end

--- 进安全状态：停机 + 锁定（**幂等**：已经锁定就直接返回）
-- 【两类锁定只有这一个入口】区别只在 allOff：
--   allOff = true  （A 类：用户开关 T0 / 硬件缺失 / 硬件变更）-> 下发一次全关
--   allOff = false （B 类：开关偏离方案 = 人工改动）-> **不动机器**，只停调度
-- 【幂等只有这一处】hardware_missing 是**电平**事件（T1 每 10 秒只要还缺件就发一次）、
--   主机开关与开关偏离每轮也都能再观测到 —— 全部由这里的 `locked` 早退吸收。
-- 【"只报一次"也只有这一处】`line` 只在**真的进锁**那一刻写一行；锁定期同一件事再发生就静默
--   （锁因已记、界面也在显示）。所以触发器不必自己写去重标志（原有三套写法已统一到这里）。
-- 【退出方式】只有用户点【启动系统】（system.start 里 unlock），没有自动恢复路径。
-- 【不覆盖锁定原因】锁定是状态：谁先出事谁是真因，后来的事件不该顶掉它（否则原因会来回跳）。
-- @param why string 锁定原因（**进日志与界面**，一句话讲清出了什么事）
-- @param allOff boolean 要不要下发一次全关
-- @param line string|nil 进锁时写的那行警告（调用方拼好；不传就不写）
-- @return boolean 本次是否真的进了安全状态
function system.enterSafeState(why, allOff, line)
    if state.system.locked then return false end
    if line then logs.warn(line) end
    if allOff then
        system.stop(why) -- 内部：下发全关 + running=false + 一行"已下发全关"日志
    else
        state.system.running = false
        logs.system(string.format("停机（%s）：保持 T1-8 现状，未下发任何指令", why))
    end
    system.lock(why)
    return true
end

--------------------------------------------------------------------------------
-- 事件入口（由 handlers 接线）
--------------------------------------------------------------------------------

--- 硬件缺失 -> 全关 + 锁定（A 类）
-- @param payload table { missing = { "净水厂主机", ... } }
function system.onHardwareMissing(payload)
    local what = table.concat((payload and payload.missing) or { "未知" }, "、")
    system.enterSafeState("硬件缺失：" .. what, true)
end

--- 主机开关是关的 -> 确保"全关 + 锁定"（A 类；**幂等**，每轮观测都对一次）
-- 不按边沿判：程序启动时主机已经是关的情况下没有边沿，否则【启动系统】按钮可点却没意义。
-- 主机重新打开后不自动恢复，仍等用户手动点【启动系统】。
-- @return boolean 本次是否真的进了安全状态
function system.ensureHostStoppedLock()
    return system.enterSafeState(HOST_OFF_REASON, true)
end

--- 实测开关偏离方案 -> 停机 + 锁定（B 类：**不动机器**，机器保持用户摆的样子）
-- 【判定只有一处】"偏离"由 watch 拿实测与**读数那一刻的方案**比出（见 watch 注释）；这里只管怎么办。
-- 【为什么"偏离"就等于"人动过"】下发只在"方案变了"时发生，而且**立即生效**（`setWorkAllowed`
--   直接写机器的 `mWorks`）。方案生效之后还偏离，就只可能有人（或外部线路）动过机器 ——
--   不需要额外证据，也不需要猜是谁发的命令。程序该做的是**尊重这个改动并停手**，
--   不是把它改回去（旧的"纠偏重发"已删，见决策 34）。
-- 【不下发全关】机器现在是用户要的状态，系统不该替他改。
-- 【幂等与去重都在 enterSafeState】这里只拼"锁因 + 那一行证据"，不自己判 locked：
--   每 5 秒还会再观察到同一次偏离，重复进来由 `locked` 早退吞掉（也就不会重复刷警告）。
-- @param payload table { level, want, got }
function system.onSwitchMismatch(payload)
    if not payload or not payload.level then return end
    local levelName    = constants.levelLabel(payload.level)

    -- 证据行：最近一次下发几秒前 / 几台 / 失败几台 ——
    --   便于对账"这次改动是不是紧接我们下发之后"（是 -> 更像通路/红石问题；不是 -> 用户动过）
    local receipt      = actuator.lastReceipt()
    local sent, failed = 0, 0
    for _, item in ipairs(receipt.items or {}) do
        sent = sent + 1
        if not item.ok then failed = failed + 1 end
    end
    local since    = (receipt.at and receipt.at > 0)
        and string.format("%d 秒前", math.max(0, math.floor(computer.uptime() - receipt.at)))
        or "无记录"
    local sentText = (sent == 0) and "还没有过下发记录"
        or string.format("最近一次下发 %s %d 台（失败 %d）", since, sent, failed)

    system.enterSafeState(levelName .. " 开关被人工改动", false, string.format(
        "%s 实测%s，方案要%s。停机并锁定（机器保持现状），处理完请点【启动系统】｜ %s",
        levelName, payload.got and "开" or "关", payload.want and "开" or "关", sentText))
end

--- 硬件台账变化 -> 采样重置 + 记录作废 + 全关 + 锁定（A 类）
-- @param payload table { changed, added, removed, levels }
function system.onHardwareChanged(payload)
    -- 采样重置与记录作废**照做**：拓扑变了，旧并行数字就不成立
    tracker.resetAll()
    if CONFIG.SYSTEM.RELEARN_ON_UNIT_CHANGE and payload then
        for _, level in ipairs(payload.levels or {}) do
            logs.system(records.invalidate(level, "该级机器增减"))
        end
    end
    -- 硬件变更属 A 类：先全关再锁定，等用户确认后再手动启用调度
    system.enterSafeState("硬件变更", true)
end

--- 全厂功率变化 -> 并行记录作废 + （在调度中才）重排
-- @param payload table { from, to, note? } note = 记账依据（如"激光仓电流被调过"），没有就是名字值
function system.onPowerChanged(payload)
    -- 换过能源仓 -> 旧并行记录不可信，作废照做（与是否在调度无关）
    if CONFIG.SYSTEM.RELEARN_ON_POWER_CHANGE then
        logs.system(records.invalidate(nil, string.format("全厂功率 %s -> %s%s",
            tostring(payload and payload.from), tostring(payload and payload.to),
            (payload and payload.note) and ("（" .. payload.note .. "）") or "")))
    end
    if not state.isActive() then return end -- 提前拦截，见 onHardwareChanged
    plan.run("功率变化")
end

--------------------------------------------------------------------------------
-- 命令入口（事件 / 界面按键 / 后续 monitor 都会走这里）
--------------------------------------------------------------------------------

--- 事件：启动
-- @param payload table|nil { reason }
function system.onSystemStart(payload)
    system.start(payload and payload.reason)
end

--- 事件：停机
-- @param payload table|nil { reason }
function system.onSystemStop(payload)
    system.stop(payload and payload.reason)
end

--- 事件：切换优先级
function system.onPriorityToggle()
    plan.togglePriority()
end

--- 开关系统（界面一个键搞定）
-- 也是"锁定后的手动恢复"入口：start 会先解锁并写一行原锁定原因
-- @param reason string
-- @return boolean 现在是不是在跑
function system.toggle(reason)
    if state.system.running then
        system.stop(reason or "手动")
        return false
    end
    system.start(reason or "手动")
    return true
end

return system
