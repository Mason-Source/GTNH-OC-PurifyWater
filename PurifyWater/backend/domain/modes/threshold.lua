--------------------------------------------------------------------------------
-- backend/domain/modes/threshold.lua
--------------------------------------------------------------------------------
-- 【职责】"阈值调度"模式 —— v4.5 之前的全部策略：
--   建议并行 = floor(全厂功率 ÷ 台数 ÷ 每并行功耗)，按级夹上限（与速率模式共用 constants.parallelCap）；
--   可开启性 = 原料保护 + 用户阈值 / 下一级 5 倍保供线（零件在 domain/rules，两套模式共用）；
--   顺序     = 低级水优先 / 高级水优先（state.priorityOrder）；
--   审计     = "用户阈值低于保供线"的文本 + 指纹 + "全 0 阈值"整块提示。
-- 【不做什么】不注册自己（main.lua 注册）、不写日志、不改运行状态、不算水位线几何（在 domain/rules）
-- 【依赖】shared/{constants,state,utils}、domain/rules
-- 【被谁用】domain/mode（按 state.system.mode 分发）
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local state     = require("shared.state")

local rules     = require("backend.domain.rules")

local threshold = {}

--- 模式名字（界面/日志用；id 由 main 注册处给）
function threshold.label() return "阈值调度" end

--- 发布：把"每级建议并行"写进 state（读侧只读 state，本函数是唯一写者）
-- 【公式（与旧版逐字一致）】建议并行 = floor(总功率 ÷ 该级台数 ÷ 该级每并行功耗)，再夹上限
--   （constants.parallelCap）；功率为 0 / 该级功耗表为 0 时取 1（下限）。
-- 【统一规则（以速率模式为规范）】**只在役前缀内发布**：未部署 / 断点之后一律 0。
-- 【唯一调用点】mode.publish()（受控触发：启动 / 功率变 / 台数变 / 模式切换）
function threshold.publish()
    local budget = state.power.all or 0
    local top    = state.serviceTop()
    for level = 1, constants.LEVEL_COUNT do
        local n = 0
        if level <= top then
            local count = math.max(1, state.plant(level).deployed or 0)
            local per   = constants.POWER_LEVELS[level] or 0
            if per <= 0 or budget <= 0 then
                n = 1
            else
                n = math.max(1, math.min(constants.parallelCap(level), math.floor(budget / (per * count))))
            end
        end
        state.plant(level).suggest = n
    end
end

--- 可开启性判定（原样搬自老的 rules.evaluate）
-- 【判定，从上到下短路】
--   ① 未部署机器                                        -> 禁止
--   ② 原料不足：本级 > 1，且上一级水 < 本级 5 倍线        -> 禁止
--   ③ 水位 < 实际执行阈值（max(用户阈值, 下一级 5 倍线)） -> 开启；否则关闭
-- @param level number 1..LEVEL_COUNT
-- @return boolean 能不能开
function threshold.evaluate(level)
    local snap = state.plant(level)
    if (snap.deployed or 0) <= 0 then return false end
    if rules.materialBlocked(level) then return false end
    return rules.belowThreshold(level)
end

--- 贪心顺序：两种优先级只差这个顺序（数据访问器仍在 shared/state）
-- @return table 等级数组
function threshold.order()
    return state.priorityOrder()
end

--- 阈值类警告的数据（文本 + 指纹 + "全 0"整块提示）
-- 【只算不打日志】"同一状态只报一次"的哨兵保留在 app/system（通用机制）
-- @return table texts
-- @return string signature
-- @return string|nil warnText
function threshold.audit()
    local texts, signature = rules.thresholdNotes()

    local warnText
    if not rules.hasPositiveThreshold() then
        warnText = "所有等级的用户阈值均为 0，暂按低保线执行；请前往【配置】页面设置阈值"
    end
    return texts, signature, warnText
end

return threshold
