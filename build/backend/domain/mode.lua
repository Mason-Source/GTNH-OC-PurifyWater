local state     = require("shared.state")
local mode      = {}
local impls     = {}
local REQUIRED  = { "label", "publish", "evaluate", "order", "audit" }
function mode.register(id, impl)
    assert(type(impl) == "table", string.format("调度模式 %s 的实现必须是表", tostring(id)))
    for _, name in ipairs(REQUIRED) do
        assert(type(impl[name]) == "function",
            string.format("调度模式 %s 缺接口 %s()", tostring(id), name))
    end
    impls[tostring(id)] = impl
end
function mode.has(id)
    return id ~= nil and impls[tostring(id)] ~= nil
end
function mode.current()
    local impl = impls[tostring(state.system.mode or "threshold")] or impls.threshold
    if not impl then
        error("没有注册任何调度模式（main.lua 里的 mode.register 漏了？）")
    end
    return impl
end
function mode.labelOf(id)
    local impl = impls[tostring(id)]
    return impl and impl.label() or tostring(id)
end
function mode.publish()
    mode.current().publish()
end
function mode.evaluate(level)
    return mode.current().evaluate(level)
end
function mode.order()
    return mode.current().order()
end
function mode.audit()
    local texts, signature, warnText, debugTexts = mode.current().audit()
    return texts, signature, warnText, debugTexts
end
return mode
