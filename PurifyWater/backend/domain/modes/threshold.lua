--------------------------------------------------------------------------------
-- backend/domain/modes/threshold.lua
--------------------------------------------------------------------------------
-- 【职责】阈值调度模式：满功率建议公式、可开启性、贪心顺序、审计
-- 【不做什么】不注册自己、不写日志、不改运行状态、不算水位线（domain/rules）
-- 【依赖】shared/{constants,state,utils}、domain/rules
-- 【被谁用】domain/mode（按 config.mode 分发）
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")

local rules     = require("backend.domain.rules")
local produce   = require("backend.domain.produce")

local threshold = {}

--- 模式名字（界面/日志用；id 由 main 注册处给）
function threshold.label() return "阈值调度" end

--- 发布每级建议到 state（唯一写者）
-- 公式：floor(总功率 ÷ 台数 ÷ 每并行功耗)，夹 constants.parallelCap；为 0 时取 1。
-- 只在役前缀内发布，未部署/断点后为 0；受控点 = mode.publish()。
function threshold.publish()
    local budget = state.read.powerAll()
    local top    = state.serviceTop()
    for level = 1, constants.LEVEL_COUNT do
        local n = 0
        if level <= top then
            local count = math.max(1, state.read.plant(level).deployed or 0)
            local per   = constants.POWER_LEVELS[level] or 0
            if per <= 0 or budget <= 0 then
                n = 1
            else
                n = math.max(1, math.min(constants.parallelCap(level), math.floor(budget / (per * count))))
            end
        end
        state.write.publishSuggest(level, n)
    end
end

--- 可开启性判定（从上到下短路）
-- ① 未部署 ② 制作自动化拦 ③ 原料不足 ④ 水位 < 实际执行阈值
-- @param level number 1..LEVEL_COUNT
-- @return boolean 能不能开
function threshold.evaluate(level)
    local snap = state.read.plant(level)
    if (snap.deployed or 0) <= 0 then return false end
    -- 制作自动化拦住（启用且未就绪 / 被拦）-> 本轮不开
    if produce.blocked(level) then return false end
    if rules.materialBlocked(level) then return false end
    return rules.belowThreshold(level)
end

--- 贪心顺序（两种优先级只差顺序）
-- @return table 等级数组
function threshold.order()
    return state.priorityOrder()
end

--- 阈值审计数据（文本+指纹+整块提示；只算不打日志）
-- @return table texts
-- @return string signature
-- @return string|nil warnText
function threshold.audit()
    local texts, signature = rules.thresholdNotes()

    local warnText
    if not rules.hasPositiveThreshold() then
        warnText = "阈值模式：用户阈值全为 0，按低保线执行（请到配置页设置阈值）"
    end
    return texts, signature, warnText
end

return threshold
