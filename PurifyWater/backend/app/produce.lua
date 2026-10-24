--------------------------------------------------------------------------------
-- backend/app/produce.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化对外用例门面：生命周期命令、周期事件转发、绑定检测
-- 【不做什么】具体绑定/侧位/巡检/就绪/job 逻辑在 backend/app/produce/* 子模块
--------------------------------------------------------------------------------

local constants      = require("shared.constants")
local logs           = require("shared.logs")
local state          = require("shared.state")
local utils          = require("shared.utils")
local scheduler      = require("core.scheduler")

local produce        = require("backend.domain.produce")
local device         = require("backend.hardware.device")
local produce_table  = require("backend.store.produce")
local produce_config = require("backend.store.produce_config")

local binding        = require("backend.app.produce.binding")
local readiness      = require("backend.app.produce.readiness")
local view           = require("backend.app.produce.view")

local patrol         = nil
local produceJobs    = nil
local produceApp     = {}

-- 侧位巡检和 operation 周期任务不在首帧路径上：首次需要时再加载。
local function patrolApp()
    patrol = patrol or require("backend.app.produce.patrol")
    return patrol
end

local function jobsApp()
    produceJobs = produceJobs or require("backend.app.produce.jobs")
    return produceJobs
end

local bindFailText = nil
local scanHoldWarned = false

local function sameRows(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        local x, y = a[i], b[i]
        if x.level ~= y.level or x.machine ~= y.machine or x.transposer ~= y.transposer
            or (tonumber(x.miss) or 0) ~= (tonumber(y.miss) or 0) then
            return false
        end
    end
    return true
end

local function notify(reason)
    scheduler.emit("produce_changed", { reason = reason })
end

--- 提交绑定并刷新依赖状态
local function commitBind(level, machine, transposer, message)
    local ok, err = binding.commit(level, machine, transposer)
    if not ok then return false, err end
    logs.system(message)
    readiness.refreshAll()
    notify("绑定：" .. tostring(machine))
    return true, nil
end

--- 启动 / 设置对账
function produceApp.reload(snapshot)
    local changedSwitch, whySwitch = produce_config.load(snapshot)

    local cleared = {}
    for level = 1, constants.LEVEL_COUNT do
        if not produce.has(level) and state.read.produceLevel(level).enabled == true then
            produce_config.set(level, false)
            cleared[#cleared + 1] = constants.levelLabel(level)
        end
    end
    if #cleared > 0 then
        changedSwitch = true
        whySwitch = "已清除未实现等级的遗留开关：" .. table.concat(cleared, "/")
        logs.warn("制作自动化：" .. whySwitch)
    end

    local entries, candidates, problems = produce_table.load()
    if #problems > 0 then
        logs.warn(string.format("制作自动化绑定表：%s%s", tostring(problems[1]),
            (#problems > 1) and ("（共 " .. #problems .. " 条问题）") or ""))
    end

    local changedBinds = not sameRows(state.read.produce().binds, entries)
        or not sameRows(state.read.produce().candidates or {}, candidates)

    binding.replaceAll(entries, candidates)
    local changedState = readiness.refreshAll()
    local changed = changedSwitch or changedBinds or changedState
    return changed, changed and "制作自动化配置已更新" or tostring(whySwitch or "制作自动化配置未变化")
end

--- T1：在线状态、候选池与就绪性刷新
-- @param scanTrusted boolean 本轮至少识别到一台净水机器；false 时冻结候选计数
function produceApp.refresh(scanTrusted)
    local result, reconcileErr = binding.reconcileScan(scanTrusted == true)
    if reconcileErr then
        logs.warn("制作自动化：" .. tostring(reconcileErr))
    end

    if result then
        if result.scanSkipped then
            local hasRows = #state.read.produce().binds > 0
                or #(state.read.produce().candidates or {}) > 0
            if hasRows and not scanHoldWarned then
                logs.warn("制作自动化：本轮未识别到可信机器，候选计数已冻结（疑似区块未加载/组件离线）")
            end
            scanHoldWarned = hasRows
        else
            scanHoldWarned = false
        end

        for _, action in ipairs(result.quarantined) do
            local b = action.entry
            logs.warn(string.format("%s 制作自动化：机器暂时扫不到，已移入删除候选（1/%d，机器 %s → 转运器 %s）",
                constants.levelLabel(b.level), constants.PRODUCE_MISSING_SCANS,
                tostring(b.machine), tostring(b.transposer)))
        end
        for _, action in ipairs(result.restored) do
            local b = action.entry
            logs.system(string.format("%s 制作自动化：候选机器重新扫到，已恢复身份（机器 %s → 转运器 %s）",
                constants.levelLabel(b.level), tostring(b.machine), tostring(b.transposer)))
        end
        for _, action in ipairs(result.deleted) do
            local b = action.entry
            logs.warn(string.format("%s 制作自动化：删除候选机器（%s，机器 %s → 转运器 %s）",
                constants.levelLabel(b.level), tostring(action.reason),
                tostring(b.machine), tostring(b.transposer)))
        end
    end

    binding.refreshOnline()
    local changed = readiness.refreshAll()
    return changed or (result and result.changed) or false
end

--- T1：原料巡检
function produceApp.patrol()
    return patrolApp().run()
end

--- 开始绑定
function produceApp.beginBind(level, machine)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if not produce.has(level) then
        return false, constants.levelLabel(level) .. " 制作自动化尚未实现"
    end
    if type(machine) ~= "string" or machine == "" then return false, "机器无效" end
    if state.read.produce().binding then return false, "已有正在进行的绑定，请先取消" end
    binding.refreshOnline()
    local existing = binding.bindOf(machine)
    if existing and binding.onlineSet()[existing.transposer] then
        return false, "该机器已绑定且转运器在线（先解绑再重绑）"
    end
    if not binding.machineSet(level)[machine] then
        return false, "机器不在该级注册表（先刷新扫描再试）"
    end

    local label = constants.levelLabel(level)
    local text  = binding.machineTextOf(level, machine)
    local snapshot, unbound = {}, {}
    for _, address in ipairs(device.scanTransposers()) do
        snapshot[address] = true
        if not binding.transposerBound(address) then unbound[#unbound + 1] = address end
    end

    -- 拆机后旧转运器通常还挂在网上。只有一个空闲转运器时可以直接复用，
    -- 用户不必为了“让它重新出现”再拔插一次；多个空闲时无法判断对应关系，不自动猜。
    if #unbound == 1 then
        local transposer = unbound[1]
        local ok, err = commitBind(level, machine, transposer, string.format(
            "%s 制作自动化：已绑定 %s… → 机器 %s（复用现有空闲转运器）",
            label, utils.shortAddress(transposer), text))
        if not ok then return false, tostring(err) end
        return true, ""
    end

    state.write.produceSetBinding({ level = level, machine = machine, snapshot = snapshot })
    logs.system(string.format("%s 制作自动化：开始绑定（机器 %s）——请放下转运器并接入网络", label, text))
    if #unbound > 0 then
        logs.warn(string.format("%s 制作自动化：网络有 %d 个未绑定转运器，无法判断对应关系", label, #unbound))
    end
    notify("开始绑定：" .. label)
    return true, ""
end

--- 取消绑定
function produceApp.cancelBind()
    local item = state.read.produce().binding
    if not item then return false, "当前没有正在进行的绑定" end
    state.write.produceSetBinding(nil)
    logs.system(string.format("%s 制作自动化：已取消绑定", constants.levelLabel(item.level)))
    notify("取消绑定")
    return true, ""
end

--- 解绑
function produceApp.unbind(machine)
    if type(machine) ~= "string" then return false, "机器无效" end
    local ok, removed, err = binding.remove(machine)
    if not ok then return false, tostring(err) end
    if not removed then return false, "该机器未绑定" end
    readiness.refreshAll()
    logs.system(string.format("%s 制作自动化：已解绑 %s…（机器 %s）",
        constants.levelLabel(removed.level), utils.shortAddress(removed.transposer),
        binding.machineTextOf(removed.level, machine)))
    notify("解绑：" .. tostring(machine))
    return true, ""
end

--- 用户开关某一级的制作自动化
function produceApp.setEnabled(level, enabled)
    level = tonumber(level)
    if not level or level < 1 or level > constants.LEVEL_COUNT then return false, "等级无效" end
    if type(enabled) ~= "boolean" then return false, "开关值无效" end
    if not produce.has(level) then
        return false, constants.levelLabel(level) .. " 制作自动化尚未实现"
    end

    local label = constants.levelLabel(level)
    if enabled == true then
        binding.refreshOnline()
        patrolApp().run(level)
        local ok, reason, units = readiness.validateForEnable(level)
        if not ok then return false, reason end
        local saved, err = produce_config.set(level, true)
        if not saved then return false, "写配置失败（settings.txt）：" .. tostring(err) end
        logs.system(string.format("%s 制作自动化：已开启（%d 台机器）", label, #units))
        notify("开关：" .. label .. " 开")
        return true, ""
    end

    local saved, err = produce_config.set(level, false)
    if not saved then return false, "写配置失败（settings.txt）：" .. tostring(err) end
    logs.system(string.format("%s 制作自动化：已关闭", label))
    notify("开关：" .. label .. " 关")
    return true, ""
end

--- 只读视图
function produceApp.read() return view.read() end

--- 周期门控转发
function produceApp.syncJobs() return jobsApp().sync() end
function produceApp.onCycleStarted(payload) return jobsApp().onCycleStarted(payload) end

--- T8：绑定中转运器检测
function produceApp.tick()
    local item = state.read.produce().binding
    if not item then return end
    local list = device.scanTransposers()
    local news = {}
    for _, address in ipairs(list) do
        if not item.snapshot[address] and not binding.transposerBound(address) then
            news[#news + 1] = address
        end
    end
    if #news == 0 then return end

    local ok, err = commitBind(item.level, item.machine, news[1], string.format(
        "%s 制作自动化：已绑定 %s… → 机器 %s", constants.levelLabel(item.level),
        utils.shortAddress(news[1]), binding.machineTextOf(item.level, item.machine)))
    if ok then
        bindFailText = nil
    elseif tostring(err) ~= bindFailText then
        bindFailText = tostring(err)
        logs.warn(string.format("%s 制作自动化：绑定失败——%s（会继续重试）",
            constants.levelLabel(item.level), tostring(err)))
    end
    if #news > 1 then
        local unbound = 0
        for _, address in ipairs(list) do
            if not binding.transposerBound(address) then unbound = unbound + 1 end
        end
        logs.warn(string.format("%s 制作自动化：网络有 %d 个未绑定转运器",
            constants.levelLabel(item.level), unbound))
    end
end

return produceApp
