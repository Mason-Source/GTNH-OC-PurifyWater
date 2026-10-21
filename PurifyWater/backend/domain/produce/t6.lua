--------------------------------------------------------------------------------
-- backend/domain/produce/t6.lua
--------------------------------------------------------------------------------
-- 【职责】T6（紫外处理）制作自动化方法：按固定顺序更换 9 种透镜
-- 【不做什么】不碰组件、不写状态；等待与转运都由 operation ctx 异步执行
-- 【依赖】无
-- 【被谁用】main.lua（注册到 backend/domain/produce）、produce_job（执行）
--
-- 【控制依据】不判断成功率，也不识别具体透镜名。机器请求下一枚透镜时，
-- 传感器里的“当前请求透镜”整行会变化；只比较这一行的签名，不关心内容是谁。
-- 2.8.4 标签：Current lens requested: ...
-- 2.9.0 key ：GT5U.infodata.purification_unit_uv_treatment.lens_requested\...
--
-- 【机器机制】透镜放入瞬间成功率就 +10%；请求间隔 3～15 秒。
-- 因此每 3 秒采样一次需求签名，确认变化后才取出当前透镜。
-- 透镜顺序固定：合成玉、琥珀、风之魔晶、绿宝石、魔力钻石、蓝黄玉、
-- 紫水晶、氟铁电气石、双锂。
--
-- 【边界处理】T6 每个周期开始先回收 itemTarget 中残留的物品。
-- 超时时保留当前透镜并失败，避免“过早取出”；下周期开头再批量回收。
-- 第 9 枚放入后直接完成且不取回，留到下周期开头回收。
-- 透镜 9 可能缺货：第 9 次投放失败视为正常收尾，成功率停在 80%。
--------------------------------------------------------------------------------

local t6 = {}

local GT_META   = "gregtech:gt.metaitem.01"
local BW_LENS   = "bartworks:gt.bwMetaGeneratedlens"
local WAIT      = 3
local MAX_PROBES = 6 -- 覆盖 3～15 秒的请求间隔

local function lens(name, damage, label)
    return { name = name, damage = damage, label = label }
end

local LENSES = {
    lens(BW_LENS, 10023, "合成玉透镜"),
    lens(GT_META, 24514, "琥珀透镜"),
    lens(GT_META, 24540, "风之魔晶透镜"),
    lens(GT_META, 24501, "绿宝石透镜"),
    lens(GT_META, 24208, "魔力钻石透镜"),
    lens(GT_META, 24513, "蓝黄玉透镜"),
    lens(GT_META, 24509, "紫水晶透镜"),
    lens(BW_LENS, 5,     "氟铁电气石透镜"),
    lens(GT_META, 24515, "双锂透镜")
}

-- 透镜 9 是可选资源：侧位配置与就绪检查只要求前 8 种。
local REQUIRED = {}
for index = 1, #LENSES - 1 do REQUIRED[index] = LENSES[index] end

t6.LENSES = LENSES
t6.priority = 6  -- 排在 T5 后、T8 前
t6.recoversTargetItems = true

--- 侧位自动配置用：来源侧需要透镜 1～8
-- 不注册 stockRequirements：运行中透镜会暂时离开来源侧，普通巡检会误判缺料。
function t6.requiredItems() return REQUIRED end

--- 该级使用物品侧（界面显示与文档语义；实际判定仍以 requiredItems 为准）
function t6.usesItems() return true end

--- 通用框架接口占位；T6 的投料在 operation 内完成
function t6.need() return {}, nil, nil end

local function readLensRequest(ctx)
    local signature, err = ctx.sensorInfo("lensRequest")
    if signature == nil then return nil, tostring(err or "透镜需求不可读") end
    signature = tostring(signature)
    if signature == "" then return nil, "透镜需求签名为空" end
    return signature, nil
end

--- 周期起点读取需求签名；最多尝试 6 次，每次间隔 3 秒。
local function waitLensRequest(ctx)
    local lastErr
    for attempt = 1, MAX_PROBES do
        if not ctx.active() then return nil, "机器 active=false" end
        local signature, err = readLensRequest(ctx)
        if signature then return signature, nil end
        lastErr = err
        if attempt < MAX_PROBES then ctx.wait(WAIT) end
    end
    return nil, lastErr or "透镜需求不可读"
end

--- 等待需求签名发生变化；变化后才允许取走当前透镜。
local function waitLensRequestChange(ctx, baseline)
    local lastErr
    for _ = 1, MAX_PROBES do
        if not ctx.active() then return nil, "机器 active=false" end
        ctx.wait(WAIT)
        local signature, err = readLensRequest(ctx)
        if signature then
            if signature ~= baseline then return signature, nil end
        else
            lastErr = err
        end
    end
    return nil, lastErr or string.format("%d 秒内透镜需求未变化", WAIT * MAX_PROBES)
end

--- 一个主周期内按固定顺序换完 9 枚透镜。
function t6.operation(ctx)
    -- 上一周期可能故意留下透镜 9，或异常中断留下其它透镜；先全部回收。
    local recovered, recoverWhy = ctx.recoverTarget()
    if not recovered then
        return false, "目标侧残留回收失败：" .. tostring(recoverWhy)
    end

    local signature, requestWhy = waitLensRequest(ctx)
    if not signature then
        return false, "读取初始透镜需求失败：" .. tostring(requestWhy)
    end

    local first = LENSES[1]
    local moved, moveWhy = ctx.transferItem(first, 1)
    if not moved then
        return false, string.format("%s 投放失败：%s", first.label, tostring(moveWhy))
    end

    for index = 1, #LENSES - 1 do
        local nextSignature, waitWhy = waitLensRequestChange(ctx, signature)
        if not nextSignature then
            -- 不取出当前透镜：过早取出会直接判配方失败；下周期由 recoverTarget 回收。
            return false, string.format("等待第 %d 枚透镜需求变化失败：%s；%s 保留在目标侧",
                index + 1, tostring(waitWhy), LENSES[index].label)
        end
        signature = nextSignature

        if not ctx.active() then return false, "机器 active=false" end

        local current = LENSES[index]
        local returned, returnWhy = ctx.returnItem(current)
        if not returned then
            return false, string.format("%s 回收失败：%s",
                current.label, tostring(returnWhy))
        end

        local nextIndex = index + 1
        local nextLens = LENSES[nextIndex]
        local inserted, insertWhy = ctx.transferItem(nextLens, 1)
        if not inserted then
            if nextIndex == #LENSES then return true end -- 透镜 9 缺货：停在 80%
            return false, string.format("%s 投放失败：%s",
                nextLens.label, tostring(insertWhy))
        end

        if nextIndex == #LENSES then
            -- 第 9 枚不能提前取回；留到下个周期开始统一回收。
            return true
        end
    end

    return true
end

return t6
