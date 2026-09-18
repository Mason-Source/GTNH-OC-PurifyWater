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
-- 【分工】键盘：X 启停 / P 优先级 / R 刷新 / T 切页 / 数字（选曲线等级，0 = 全部）
--         鼠标：页签、净水状态块（行→详情；详情态下点任意处→返回）、图表等级按钮、
--               配置页（点行选中 / 点勾选切换 / 点虚拟键盘改阈值）、日志标题、按钮
--   Q 退出不在这里：退出语义归 core/runtime（runtime.bindQuitKeys）。
-- 【阈值输入】物理键盘不进输入框：点某级**选中**它，再用常驻虚拟键盘改。键的语义（kind/value）
--   由面板随热区带过来 —— 键盘长什么样归面板，按下去怎么改归这里；缓冲是 kL 整数串，
--   只在提交那一刻 ×1000 变 mB。
-- 【不弹提示】命令结果只写系统日志（省掉那个几秒后消失的提示条）。
--------------------------------------------------------------------------------

local utils     = require("shared.utils")
local constants = require("shared.constants")
local CONFIG    = require("shared.config")
local logs      = require("shared.logs")
local api       = require("backend.api")
local viewmodel = require("frontend.viewmodel")
local fstate    = require("frontend.state")

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
-- 清掉选中与缓冲：配置页的"选中/半填的缓冲"不跨页保留，回来是干净状态
--   （也免得缓冲默默留在内存里）。
-- @param tab string "overview" | "config"
local function switchTab(tab)
    if fstate.currentTab == tab then return end
    fstate.currentTab = tab
    fstate.configSel, fstate.configBuf = nil, nil
    fstate.invalidateAll()
end

--- 选中某一级开始编辑：缓冲 = 它当前的阈值（kL 整数串，界面一律 kL）
-- @param level number
local function selectLevel(level)
    local row        = fstate.lastData and fstate.lastData.levels[level]
    local milli      = row and (row.rule.threshold or 0) or 0
    fstate.configSel = level
    fstate.configBuf = tostring(math.floor(milli / 1000))
end

--- 配置页虚拟键盘：按下一个键
-- 【语义表（面板只负责画和带 value，怎么改在这里）】
--   digit -> 追加（从 "0" 开始时不粘 0）；mul / div -> 乘 / 整除（倍数键，如 x10、/100）；
--   set -> 覆盖成档位值；back -> 删末位；clear -> 空；copy -> 抄上一级的阈值；
--   cancel -> 弃掉选中；commit -> 交给调用方发命令
-- 上界按"运算后的**数值**"判：≥ 1e14 kL 一律不响应（**含等于**）——
--   空串是合法中间态（清空后接着敲），所以空串放行、其余一律按数值判。
--   按位数判会漏：倍数键是"先算后判"，一步就能跨过位数边界。
-- @param key table { kind = , value = }
-- @return string|nil "commit" = 该发 level_rules_set 了（值看 fstate.configBuf）
local function applyKey(key)
    local limit = CONFIG.UI.MAX_THRESHOLD_KILO or 100000000000000

    if key.kind == "cancel" then
        fstate.configSel, fstate.configBuf = nil, nil
        logs.debug("[调试] 退出编辑（用户点了 ✘）")
        return nil
    end
    if not fstate.configSel then return nil end
    if key.kind == "commit" then
        local value = tonumber(fstate.configBuf or "")
        if not value then
            logs.ui("还没填数字，未保存")
            return nil
        end
        if value >= limit then
            logs.ui("超过上限（≥ 1e14 kL），未保存")
            return nil
        end
        return "commit"
    end

    local buf = fstate.configBuf or ""
    if key.kind == "digit" then
        if buf == "0" then buf = "" end -- 从 0 开始就别再粘 0（否则 "0" + "5" 变成 "05"）
        buf = buf .. key.value
    elseif key.kind == "mul" or key.kind == "div" then
        local n     = tonumber(buf) or 0
        local scale = tonumber(key.value) or 1
        buf         = tostring((key.kind == "mul") and (n * scale) or math.floor(n / scale))
    elseif key.kind == "set" then
        buf = key.value
    elseif key.kind == "back" then
        buf = buf:sub(1, math.max(0, #buf - 1))
    elseif key.kind == "clear" then
        buf = ""
    elseif key.kind == "copy" then
        local row = fstate.lastData and fstate.lastData.levels[fstate.configSel - 1]
        if row then buf = tostring(math.floor((row.rule.threshold or 0) / 1000)) end
    end

    if buf ~= "" then
        local value = tonumber(buf)
        if not value or value >= limit then
            logs.ui("超过上限（≥ 1e14 kL），这一下没生效")
            return nil
        end
    end
    fstate.configBuf = buf
    return nil
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
    elseif utils.isKey(char, code, "p") then
        fire("priority_toggle")
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
    -- 不 invalidateAll：详情与列表是同一格位的两套内容，只让 status 的指纹变，
    --   下一帧只重画这一块。
    -- 【必须限定总览页】报表页是整屏面板，它盖住同一片坐标（不限定就会把报表页的可编辑格吃掉）
    if fstate.currentTab == "overview" and fstate.hit(fstate.areas.status, x, y) then
        if fstate.detailLevel then
            fstate.detailLevel = nil
        else
            for level, box in pairs(fstate.levelRows or {}) do
                if fstate.hit(box, x, y) then
                    fstate.detailLevel = level
                    break
                end
            end
        end
        return
    end

    -- 日志面板标题 -> 切 user/debug
    if fstate.hit(fstate.logTitle, x, y) then
        fire("log_level_toggle")
        return
    end

    -- 图表标题行的等级按钮（0 = 全部）
    for level, box in pairs(fstate.chartChips or {}) do
        if fstate.hit(box, x, y) then
            setChartLevel(level)
            return
        end
    end

    -- 配置页：从下往上判：键盘（最下）-> 勾选格 -> 选中整行
    --   顺序理由：勾选格落在行内，整行热区会把它包住 —— 先判细的才点得准
    if fstate.currentTab == "config" then
        -- ① 虚拟键盘：按语义改缓冲；✔ 才真发命令（命令只有一个出口：fire）
        for _, box in ipairs(fstate.keyCells or {}) do
            if fstate.hit(box, x, y) then
                local level = fstate.configSel
                if applyKey(box) == "commit" then
                    local kilo = tonumber(fstate.configBuf or "")
                    if kilo and level then
                        fire("level_rules_set", level, kilo * 1000, nil)
                        -- 保存完不再吊着那一行的选中：回显行回到"未选中"、键盘随之变灰
                        --   （想改再点一次即可）。
                        fstate.configSel, fstate.configBuf = nil, nil
                    end
                end
                return
            end
        end
        -- ② 勾选格：只切勾选，不算选中
        for level, box in pairs(fstate.checkCells or {}) do
            if fstate.hit(box, x, y) then
                fire("level_enabled_toggle", level)
                return
            end
        end
        -- ③ 整行：选中它（缓冲直接填当前值，"选中就能改"）
        for level, box in pairs(fstate.configRows or {}) do
            if fstate.hit(box, x, y) then
                selectLevel(level)
                return
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
