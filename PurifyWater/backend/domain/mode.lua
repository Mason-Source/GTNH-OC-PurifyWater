--------------------------------------------------------------------------------
-- backend/domain/mode.lua
--------------------------------------------------------------------------------
-- 【职责】调度模式的**注册与分发**：全工程只有这一处按 state.system.mode 选策略
-- 【不做什么】不含任何具体策略（建议并行 / 可开启性 / 顺序 / 审计都在 backend/domain/modes/*）
-- 【依赖】shared/state
-- 【被谁用】domain/power（建议并行）、domain/allocator（顺序 + 判定）、
--           app/{watch,system}（重判 / 审计）、main（启动注册）
--
-- 【为什么要它】v4.5 之前只有"阈值调度"一套，公式散在 power/rules/system 里；加第二套
--   （速率）之前先把策略收成插件：通用层只认下面这几个接口，加模式 = 加一个
--   backend/domain/modes/<id>.lua + 在 main.lua 注册一行。
--
-- 【接口（每个模式实现必须提供）】
--   label()         -> string                        人话名字（界面/日志用；id 由注册处给）
--   publish()       -> nil                           把"每级建议并行"整批发布到 state（唯一写 suggest 的地方）
--   evaluate(level) -> boolean                       可开启性判定（能不能开；理由不上屏/不进日志）
--   order()         -> table                         贪心调度的等级顺序（数组）
--   audit()         -> texts, signature, warnText, debugTexts
--                     一次性提示的**数据**（逐条 user 文本 + "全 0/T1 未部署"整块提示 + debug 明细；
--                     只报一次的哨兵在 app/system）
--------------------------------------------------------------------------------

local state     = require("shared.state")

local mode      = {}

local impls     = {}

local REQUIRED  = { "label", "publish", "evaluate", "order", "audit" }

--- 注册一个模式实现（main 启动时调；校验接口完整性，缺一个就早报错）
-- @param id string
-- @param impl table
function mode.register(id, impl)
    assert(type(impl) == "table", string.format("调度模式 %s 的实现必须是表", tostring(id)))
    for _, name in ipairs(REQUIRED) do
        assert(type(impl[name]) == "function",
            string.format("调度模式 %s 缺接口 %s()", tostring(id), name))
    end
    impls[tostring(id)] = impl
end

--- 这个 id 注册过了吗（main 校验 settings 里的 mode 用）
-- @param id string|nil
-- @return boolean
function mode.has(id)
    return id ~= nil and impls[tostring(id)] ~= nil
end

--- 当前模式实现
-- 【不抛错找策略】main 启动时已把未知 mode 回退成 threshold；这里再兜一层，
--   取不到才报错 —— 报错信息要能一眼看出"是忘了注册"。
-- @return table
function mode.current()
    local impl = impls[tostring(state.system.mode or "threshold")] or impls.threshold
    if not impl then
        error("没有注册任何调度模式（main.lua 里的 mode.register 漏了？）")
    end
    return impl
end

--- 某个已注册模式的名字（切换日志用；不存在就返回 id 本身）
-- @param id string
-- @return string
function mode.labelOf(id)
    local impl = impls[tostring(id)]
    return impl and impl.label() or tostring(id)
end

--- 发布"每级建议并行"到 state —— 由当前模式实现（受控调用，见 domain/modes/* 的 publish）
-- @return string|nil 给用户看的"扩产建议"一行（阈值模式返回 nil）；日志由 app 层打
function mode.publish()
    return mode.current().publish()
end

--- 可开启性判定 —— 由当前模式给
-- @param level number
-- @return boolean 能不能开
function mode.evaluate(level)
    return mode.current().evaluate(level)
end

--- 贪心调度的等级顺序 —— 由当前模式给
-- @return table 等级数组
function mode.order()
    return mode.current().order()
end

--- 一次性提示的数据（只算，不打日志；"同一状态只报一次"的哨兵在 app/system）
-- @return table texts
-- @return string signature
-- @return string|nil warnText
-- @return table debugTexts
function mode.audit()
    local texts, signature, warnText, debugTexts = mode.current().audit()
    return texts, signature, warnText, debugTexts
end

return mode
