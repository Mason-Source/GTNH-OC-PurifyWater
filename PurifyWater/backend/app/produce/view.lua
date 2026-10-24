--------------------------------------------------------------------------------
-- backend/app/produce/view.lua
--------------------------------------------------------------------------------
-- 【职责】制作自动化前端只读投影
-- 【不做什么】不写状态、不碰组件、不改绑定
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")
local machines  = require("backend.hardware.machines")
local produce   = require("backend.domain.produce")
local interface = require("backend.domain.produce.interface")
local binding   = require("backend.app.produce.binding")
local readiness = require("backend.app.produce.readiness")

local view = {}

--- 制作自动化只读视图
function view.read()
    local online = binding.onlineSet()
    local candidates = binding.candidates()
    local missingByLevel = {}
    for _, c in ipairs(candidates) do
        missingByLevel[c.level] = (missingByLevel[c.level] or 0) + 1
    end
    local levels = {}
    for level = 1, constants.LEVEL_COUNT do
        local entry      = state.read.produceLevel(level)
        local st, reason = readiness.stateOf(level)
        local method     = produce.method(level)
        local applicable = interface.applicable(method)

        local list, bound, onlineCount, configured = {}, 0, 0, 0
        for _, m in ipairs(machines.of(level)) do
            local b         = binding.bindOf(m.address)
            local sub       = b and state.read.produce().subs[b.machine] or nil
            local subOnline = (b and online[b.transposer]) or nil
            local sideState = "-"
            if b and applicable and subOnline then
                sideState = (sub and sub.sides) and "ok" or "auto"
                if sub and sub.sides then configured = configured + 1 end
            end
            list[#list + 1] = {
                address   = m.address,
                text      = binding.machineTextOf(level, m.address),
                bound     = b and b.transposer or nil,
                online    = subOnline,
                sideState = sideState,
                sideFail  = (subOnline and sub) and sub.sideFail or nil,
                rate      = subOnline and sub and sub.rate or nil
            }
            if b then bound = bound + 1 end
            if subOnline then onlineCount = onlineCount + 1 end
        end

        levels[level] = {
            implemented = method ~= nil,
            enabled     = entry.enabled == true,
            state       = st,
            reason      = reason,
            ready       = entry.valid == true,
            count       = #list,
            bound       = bound,
            online      = onlineCount,
            configured  = configured,
            missing     = missingByLevel[level] or 0,
            machines    = list
        }
    end

    local b = state.read.produce().binding
    local bindingInfo = nil
    if b then
        bindingInfo = {
            level = b.level,
            machine = b.machine,
            text = binding.machineTextOf(b.level, b.machine)
        }
    end
    return {
        binding    = bindingInfo,
        candidates = {
            count = #candidates,
            limit = constants.PRODUCE_MISSING_POOL_MAX
        },
        levels     = levels
    }
end

return view
