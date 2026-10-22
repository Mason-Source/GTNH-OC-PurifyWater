--------------------------------------------------------------------------------
-- backend/domain/produce.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化框架：等级→方法注册/分发、就绪性检查（纯判据）、blocked 判定
-- 【不做什么】不碰组件（硬件事实由调用方注入）、不写盘、不写日志
-- 【依赖】shared/{constants,state}
-- 【被谁用】main（注册方法）、backend/app/produce（检查与状态）、domain/modes/*（blocked 判定）
--
-- 【解耦铁律】produce 侧不得 require 任何调度侧模块（domain/mode、domain/modes/*、
--   domain/{power,allocator}、app/*）；调度侧只允许调用 produce.blocked(level) 这一个只读判定。
--
-- 方法模块接口（等级强挂钩；加新级 = 新文件 + main.lua 注册一行）：
--   need(sensorLines) -> { {fluid|any, amount, label}, ... }  本轮需求（控制信号位规则）
--   requiredFluids() -> { {id,label} | {label=, any={…}}, ... }  侧位自动配置用（可选）
--   stockRequirements() -> { {fluid|any, amount, label}, ... }  原料巡检用（可选；全部流体各一份）
--   requiredItems() -> { {name, damage, label}, ... }  侧位自动配置用（可选；T4 物品源）
--   usesItems() -> boolean  该级需要物品输出侧（可选；T4）
--   fluidUnit() -> number  流体单笔步长（可选；T4=10L）
--   patrolByNeed() -> boolean  原料巡检按 need() 的当前需求检查（可选；T4）
--   minTransferRate() -> number|nil  该级最低转运速率（可选；低于则判未就绪）
--   operation(ctx) -> boolean, reason  该级一次操作的流程（可选；由 app 登记到 produce_runtime）
--   priority -> number|nil  该级 operation 的调度优先级（可选；越小越优先）
--   当前顺序：T5(5) > T6(6) > T8(10) > T3(20) > T4(30) > T7(40)
--   recoversTargetItems -> boolean  operation 自行回收目标侧残留物品（可选；T6）

-- 【判据】就绪 = 该级机器全部已绑定 + 绑定的转运器都在网；
--   运行期拦截 = 未就绪 或 原料巡检维护的强制关断（forceOff）。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")
local check     = require("backend.domain.produce.check")

local produce   = {}

local impls     = {}
local REQUIRED  = { "need" }

--- 注册某等级的方法实现（缺接口早报错）
-- @param level number 1..LEVEL_COUNT
-- @param impl table
function produce.register(level, impl)
    level = tonumber(level)
    assert(level and level >= 1 and level <= constants.LEVEL_COUNT,
        "制作自动化方法等级越界：" .. tostring(level))
    assert(type(impl) == "table",
        string.format("%s 的制作自动化方法实现必须是表", constants.levelLabel(level)))
    for _, name in ipairs(REQUIRED) do
        assert(type(impl[name]) == "function",
            string.format("%s 的制作自动化方法缺接口 %s()", constants.levelLabel(level), name))
    end
    impls[level] = impl
end

--- 该等级是否注册过方法
-- @param level number
-- @return boolean
function produce.has(level)
    return impls[level] ~= nil
end

--- 某等级的方法实现（未注册返回 nil）
-- @param level number
-- @return table|nil
function produce.method(level)
    return impls[level]
end

--- 就绪性检查（兼容出口）
produce.check = check.run

--- 与调度之间的唯一接口：该级当前是否被制作自动化拦住
-- 启用且未就绪（invalid / 强制关断）-> true；未启用 -> false。
-- 【运行期拦的是"绑定齐 + 在网"（invalid）与原料巡检维护的强制关断（forceOff）】
--   运行中用户改容器触发重配时，调度绝不能把该级关掉（只暂停转运，配好自动恢复）。
-- @param level number
-- @return boolean
function produce.blocked(level)
    -- 未注册实现级永远不参与调度拦截（即使 settings.txt 里留有旧开关）。
    if not produce.has(level) then return false end
    local entry = state.read.produceLevel(level)
    if entry.enabled ~= true then return false end
    if entry.valid ~= true then return true end
    for _, sub in pairs(state.read.produce().subs) do
        if sub.level == level and sub.forceOff == true then return true end
    end
    return false
end

return produce
