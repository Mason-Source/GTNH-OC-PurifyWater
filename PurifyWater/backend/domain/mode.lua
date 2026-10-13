--------------------------------------------------------------------------------
-- backend/domain/mode.lua
--------------------------------------------------------------------------------
-- 【职责】调度模式注册与分发：唯一按 config.mode 选策略处
-- 【不做什么】不含任何具体策略（建议并行 / 可开启性 / 顺序 / 审计都在 backend/domain/modes/*）
-- 【依赖】shared/state
-- 【被谁用】domain/power（建议并行）、domain/allocator（顺序 + 判定）、
--           app/{watch,system}（重判 / 审计）、main（启动注册）
--
-- 加模式 = 新增 backend/domain/modes/<id>.lua 并在 main.lua 注册一行。
--
-- 模式接口：
--   label() -> string                    界面/日志名
--   publish() -> nil                     发布每级建议到 state（唯一写 suggest）
--   evaluate(level) -> boolean           可开启性
--   order() -> table                     贪心顺序
--   audit() -> texts, signature, warnText, debugTexts   一次性提示数据（哨兵在 app/system）
--------------------------------------------------------------------------------

local state     = require("shared.state")

local mode      = {}

local impls     = {}

local REQUIRED  = { "label", "publish", "evaluate", "order", "audit" }

--- 注册模式实现（main 启动时调，缺接口早报错）
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

--- 该 id 是否已注册
-- @param id string|nil
-- @return boolean
function mode.has(id)
    return id ~= nil and impls[tostring(id)] ~= nil
end

--- 当前模式实现
-- main 启动时已回退未知 mode；此处取不到才报错。
-- @return table
function mode.current()
    local impl = impls[tostring(state.read.mode() or "threshold")] or impls.threshold
    if not impl then
        error("没有注册任何调度模式")
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

--- 发布每级建议到 state（受控调用）；返回扩产建议一行，日志由 app 层打。
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
