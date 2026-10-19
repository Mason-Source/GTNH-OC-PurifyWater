--------------------------------------------------------------------------------
-- frontend/input.lua
--------------------------------------------------------------------------------
-- 【职责】输入 -> 命令：**唯一映射处**（键盘与鼠标事件都在这里翻译成 `api.exec(...)`）
-- 【不做什么】不画图、不判断业务（能不能点，由面板决定是否登记热区）
-- 【依赖】frontend/{state,viewmodel}、backend/api、shared/{utils,constants,config,logs}
-- 【被谁用】frontend/render（订阅事件后转进来）
--
-- 【载荷形态】外部事件（key_down / touch）派发过来的是 **event.pull 的原始数组**：
--   key_down = { "key_down", 键盘地址, char, code, 玩家 }   <- char 是数字 ASCII 码
--   touch    = { "touch", 屏幕地址, x, y, 玩家 }
-- 【分工】键盘：X 启停 / R 刷新 / T 切页 / 数字（选曲线等级，0 = 全部）
--   （优先级/阈值约束都是"当前模式的子参数"，只在总览页用按钮切，不再占快捷键）
--         鼠标：页签、净水状态块（行→详情；详情态下点任意处→返回）、图表等级按钮、
--               配置页（点表格里某一格 = 选中它 -> 键盘槽换成那一列自己的键盘；
--                       点「运行设置」的自启子项行 = 切开机自启）、日志标题、按钮
--   Q 退出不在这里：退出语义归 core/runtime（runtime.bindQuitKeys）。
-- 【配置页输入】物理键盘不进输入框：点表格里某一格**选中**它，卡内键盘槽换成那一列的键盘。
--   键的语义（kind/value）由面板随热区带过来 —— 键盘长什么样归面板，按下去怎么改归这里。
--   数字列（阈值 / 权重）先改缓冲再点 ✔ 提交；增产是选项键盘（点哪个键就提交哪个）；勾选 / 制作自动化点格子直接切换。
--   阈值缓冲是 kL 整数串，只在提交那一刻 ×1000 变 mB。
-- 【不弹提示】命令结果只写系统日志（省掉那个几秒后消失的提示条）。
--------------------------------------------------------------------------------

local utils     = require("shared.utils")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local api       = require("backend.api")
local viewmodel = require("frontend.viewmodel")
local fstate    = require("frontend.state")
local viewinput = require("frontend.viewinput")

local input     = {}

--- 发命令：让视图缓存过期（下一帧按指纹局部重绘）
-- 成功不回执：后端各自都写了日志（启停/调度/阈值/广播…），界面再写一行就是同一件事两行。
-- 只有**被拒**才由界面说话 —— 那种后端不写、用户又必须知道。
-- @param command string
-- @param ... any
-- @return boolean ok
local function fire(command, ...)
    local ok, text = api.exec(command, ...)
    if not ok and text and text ~= "" then
        logs.ui(tostring(text))
    end
    viewmodel.expire()
    return ok
end

-- 键盘扫描码统一从 constants.KEY_CODES 取（扫描码只存一处）。
-- 没有 ENTER/ESCAPE/BACKSPACE：阈值改由配置页虚拟键盘输入，物理键盘不进输入框。

--- 切页（页签与 T 键共用）
-- 清选中与缓冲：不跨页保留，回来是干净状态。
-- @param tab string "overview" | "config"
local function switchTab(tab)
    if fstate.currentTab == tab then return end
    fstate.currentTab = tab
    fstate.editLevel, fstate.editField, fstate.editBuf = nil, nil, nil
    fstate.invalidateAll()
end

--- 点表格里的某一格 = 选中它（键盘槽随即换成那一列的键盘）
-- 数字列（阈值 / 权重）的缓冲直接填当前值 —— "选中就能改"；收集列（回流/双锂/增产）用不着缓冲。
-- 勾选不在这一路：它是**点一下直接切换**（见 applyCell），不选中、不开键盘。
-- @param level number
-- @param field string "threshold" / "weight" / "boost"
local function selectCell(level, field)
    if fstate.editLevel == level and fstate.editField == field then
        fstate.editLevel, fstate.editField, fstate.editBuf = nil, nil, nil
        return
    end
    local row = fstate.lastData and fstate.lastData.levels[level]
    fstate.editLevel, fstate.editField = level, field

    if field == "threshold" then
        local milli    = (row and row.rule.threshold) or 0
        fstate.editBuf = tostring(math.floor(milli / 1000))
    elseif field == "weight" then
        fstate.editBuf = tostring(math.floor(tonumber(row and row.weight) or 0))
    else
        fstate.editBuf = nil
    end
end

--- 点标题行右侧的"利用因子" = 选中它（全局字段，无等级）
local function selectFactor()
    local sys = fstate.lastData and fstate.lastData.system
    fstate.editLevel, fstate.editField = nil, "factor"
    fstate.editBuf = tostring(math.floor(tonumber(sys and sys.energyFactor) or 100))
end

--- 点标题行右侧的"无线范围" = 选中它（全局字段，无等级）
local function selectStrength()
    local netState = fstate.lastData and fstate.lastData.net
    fstate.editLevel, fstate.editField = nil, "strength"
    fstate.editBuf = tostring(math.floor(tonumber(netState and netState.strength) or CONFIG.NET.STRENGTH))
end

--- 放下没提交的东西（保存完 / 点 ✘ / 切页都走这里）
local function clearEdit()
    fstate.editLevel, fstate.editField, fstate.editBuf = nil, nil, nil
end

--- 点表格里的某一格
-- 勾选格点即切换，不开键盘；其它格选中后换对应键盘。
-- 取反是界面语义：后端只认"设成什么"（level_enabled_set(level, enabled)），不做读-改-写。
-- @param level number
-- @param field string "enabled" / "threshold" / "weight" / "boost"
local function applyCell(level, field)
    -- 制作自动化：点格子 = 打开该级面板（绑定 / 解绑 / 开关都在面板里）
    if field == "produce" then
        local row = fstate.lastData and fstate.lastData.levels[level]
        if not row or row.produceClickable ~= true then return end
        selectCell(level, "produce")
        fstate.producePage = 1
        return
    end
    if field ~= "enabled" then
        selectCell(level, field)
        return
    end
    local row = fstate.lastData and fstate.lastData.levels[level]
    if not row then return end
    fire("level_enabled_set", level, not (row.rule.enabled == true))
end

--- 键盘槽：按下一个键（键盘长什么样归面板，按下去怎么改归这里）
-- 【阈值 / 权重】数字列，要点 ✔ 才提交：
--   digit -> 追加（从 "0" 开始不粘 0）；mul / div -> 乘 / 整除；set -> 覆盖成档位值；
--   back -> 删末位；clear -> 空；copy -> 抄上一级阈值；commit -> 提交；cancel -> 弃掉选中。
-- 【收集】复合选项列，点哪个键就发哪个命令（没有"确定"这一步）；勾选不走键盘（点格子直接切换）。
-- 上界按"运算后的**数值**"判：阈值 ≥ 1e14 kL、权重 > MAX 一律不响应（空串是合法中间态，放行）——
--   按位数判会漏：倍数键是"先算后判"，一步就能跨过位数边界。
-- @param key table { kind = , value = }
local function applyKey(key)
    local field, level = fstate.editField, fstate.editLevel
    if not field then return end
    if field ~= "factor" and field ~= "strength" and not level then return end
    local kind = key.kind

    if kind == "cancel" then
        logs.debug("退出编辑（✘）")
        clearEdit()
        return
    end

    -- ① 复合选项列（T1/T2 回流、T6 双锂、T7 增产）：点哪个键就发哪个命令
    if field == "boost" then
        if kind == "set_boost" then
            fire("t7_boost_set", tonumber(key.value))
            clearEdit()
        elseif kind == "set_reflux" then
            fire("reflux_set", level, key.value == true)
            clearEdit()
        elseif kind == "set_t6_dual" then
            fire("t6_dual_lithium_set", key.value == true)
            clearEdit()
        end
        return
    end

    -- ② 数字列（阈值 / 权重）：改缓冲，点 ✔ 才提交
    local isThreshold = (field == "threshold")
    local isFactor    = (field == "factor")
    local isStrength  = (field == "strength")
    local limit       = isThreshold and (CONFIG.UI.MAX_THRESHOLD_KILO or 100000000000000)
        or isFactor and CONFIG.ENERGY.FACTOR_MAX
        or isStrength and CONFIG.NET.STRENGTH_MAX
        or (CONFIG.RATES.MAX_WEIGHT or 100)

    if kind == "commit" then
        local value = tonumber(fstate.editBuf or "")
        if not value then
            logs.ui("未填数字，未保存")
            return
        end
        if isThreshold then
            if value >= limit then
                logs.ui("超过上限（≥ 1e14 kL），未保存")
                return
            end
            fire("level_rules_set", level, value * 1000, nil)
        elseif isFactor then
            if value < CONFIG.ENERGY.FACTOR_MIN or value > limit then
                logs.ui(string.format("利用因子需为 %d-%d 的整数，未保存",
                    CONFIG.ENERGY.FACTOR_MIN, limit))
                return
            end
            fire("energy_factor_set", value)
        elseif isStrength then
            if value < 0 or value > limit then
                logs.ui(string.format("无线范围需为 0-%d 的整数（方块），未保存", limit))
                return
            end
            fire("net_strength_set", value) -- 超卡上限由后端/网卡夹取
        else
            if value < 0 or value > limit then
                logs.ui(string.format("权重需为 0-%d 的整数，未保存", limit))
                return
            end
            fire("weight_set", level, value)
        end
        clearEdit()
        return
    end

    local buf = fstate.editBuf or ""
    if kind == "digit" then
        if buf == "0" then buf = "" end -- 从 0 开始就别再粘 0（否则 "0" + "5" 变成 "05"）
        buf = buf .. key.value
    elseif kind == "mul" or kind == "div" then
        local n     = tonumber(buf) or 0
        local scale = tonumber(key.value) or 1
        buf         = tostring((kind == "mul") and (n * scale) or math.floor(n / scale))
    elseif kind == "set" then
        buf = key.value
    elseif kind == "back" then
        buf = buf:sub(1, math.max(0, #buf - 1))
    elseif kind == "clear" then
        buf = ""
    elseif kind == "copy" then
        local prev = fstate.lastData and fstate.lastData.levels[level - 1]
        if prev then buf = tostring(math.floor((prev.rule.threshold or 0) / 1000)) end
    end

    if buf ~= "" then
        local value = tonumber(buf)
        -- 上界：阈值"≥上限即拒绝"（独占）；权重 / 因子含端点（> 才拒绝）
        local over
        if not value then over = true
        elseif isThreshold then over = (value >= limit)
        else over = (value > limit) end
        if over then
            local name = isFactor and "利用因子" or isStrength and "无线范围" or "权重"
            logs.ui(isThreshold and "超过上限（≥ 1e14 kL），未生效"
                or string.format("%s上限 %d，未生效", name, limit))
            return
        end
    end
    fstate.editBuf = buf
end

--- 切换图表看的等级（0 = 全部）；窗口秒数由 viewmodel 按等级重算，所以要让它过期
-- @param level number
local function setChartLevel(level)
    fstate.chartLevel = level
    viewmodel.expire()
end

--- 键盘
-- @param char number|string|nil
-- @param code number|nil
local function onKey(char, code)
    if utils.isKey(char, code, "x") then
        -- 启动拦在这里（不等后端拒）：
        --   按钮那边是"不登记热区"（点不到），键盘这条路径必须用**同一个判据**拦，
        --   否则会出现"按钮灰着、按 X 却能发出命令"。运行中按 X 是停机，不拦。
        local blocked = viewmodel.startBlockedReason(fstate.lastData)
        if blocked then
            logs.ui("启动被拦下：" .. blocked)
        else
            fire("system_toggle")
        end
    elseif utils.isKey(char, code, "r") then
        fire("refresh")
    elseif utils.isKey(char, code, "t") then
        switchTab((fstate.currentTab == "overview") and "config" or "overview")
    else
        local key   = utils.keyChar(char)
        local level = key and tonumber(key)
        if level and level >= 0 and level <= constants.LEVEL_COUNT then
            setChartLevel(level)
        end
    end
end

--- 鼠标
-- @param x number
-- @param y number
local function onClick(x, y)
    for key, box in pairs(fstate.tabs) do
        if fstate.hit(box, x, y) then
            switchTab(key)
            return
        end
    end

    -- 【净水状态面板】详情态：点这块矩形任意处 -> 返回列表；列表态：点某一行 -> 看该级详情
    -- 命中判定与镜像端共用（frontend/viewinput）；不 invalidateAll：详情与列表是同一格位的
    --   两套内容，只让 status 的指纹变，下一帧只重画这一块。
    if viewinput.statusArea(x, y) then return end

    -- 日志面板标题 -> 切 user/debug
    if fstate.hit(fstate.logTitle, x, y) then
        fire("log_level_toggle")
        return
    end

    -- 图表标题行的等级按钮（0 = 全部）：命中判定与镜像端共用；主端要让窗口秒数跟着重算
    if viewinput.chartChip(x, y) then
        viewmodel.expire()
        return
    end

    -- 配置页：先键盘槽（细），再表格的每一格 —— 键盘槽在表格外面，格子之间不重叠
    if fstate.currentTab == "config" then
        -- ① 键盘槽：按语义改缓冲 / 选项列直接提交（命令只有一个出口：fire）
        for _, box in ipairs(fstate.keys or {}) do
            if fstate.hit(box, x, y) then
                applyKey(box)
                return
            end
        end
        -- ①b 制作自动化面板的热区（与键盘槽同一块区域，互斥出现）
        for _, box in ipairs(fstate.produceHits or {}) do
            if fstate.hit(box, x, y) then
                if box.act == "page" then
                    fstate.producePage = (fstate.producePage or 1) + (tonumber(box.value) or 0)
                    viewmodel.expire()
                elseif box.act == "bind" then
                    fire("produce_bind_begin", fstate.editLevel, box.machine)
                elseif box.act == "unbind" then
                    fire("produce_unbind", box.machine)
                elseif box.act == "cancel" then
                    fire("produce_bind_cancel")
                elseif box.act == "toggle" then
                    local row = fstate.lastData and fstate.lastData.levels[fstate.editLevel]
                    fire("level_produce_set", fstate.editLevel, not (row and row.produceEnabled == true))
                end
                return
            end
        end
        -- ② 标题行右侧的两个全局字段：无线范围 / 利用因子
        if fstate.hit(fstate.strengthCell, x, y) then
            selectStrength()
            return
        end
        if fstate.hit(fstate.factorCell, x, y) then
            selectFactor()
            return
        end
        -- ③ 运行设置自启行：整行热区；说明行不登记。
        if fstate.hit(fstate.autostartRow, x, y) then
            fire("autostart_toggle")
            return
        end
        -- ④ 表格：勾选 / 制作自动化格点一下直接切换；阈值 / 权重 / 增产格 = 选中它（"增产"只有 T7 那一行登记热区）
        for level, cell in pairs(fstate.cells or {}) do
            for field, box in pairs(cell) do
                if fstate.hit(box, x, y) then
                    applyCell(level, field)
                    return
                end
            end
        end
        return
    end

    -- 按钮
    local _, box = fstate.buttonAt(x, y)
    if box and box.action then
        fire(box.action)
    end
end

--- 处理一个外部事件
-- @param name string 事件名
-- @param payload table event.pull 的原始数组
-- @return boolean 是否处理了
function input.handle(name, payload)
    payload = payload or {}
    if name == "key_down" then
        onKey(payload[3], payload[4])
        return true
    end
    if name == "touch" then
        local x, y = payload[3], payload[4]
        if type(x) == "number" and type(y) == "number" then
            onClick(x, y)
            return true
        end
    end
    return false
end

--- 记住本帧数据（编辑阈值要读"当前值"）
-- @param data table vm.build() 的返回
function input.attach(data)
    fstate.lastData = data
end

return input
