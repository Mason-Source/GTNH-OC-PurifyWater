--------------------------------------------------------------------------------
-- backend/hardware/gt_infodata.lua
--------------------------------------------------------------------------------
-- 【层次】后端 / 硬件适配（**纯解析**，不碰任何组件对象）
-- 【职责】把 GregTech 的 `getSensorInformation()` 返回值（字符串数组）解析成结构化数据。
--
-- 独立成模块：v2 的 sensors.lua 走"关键字 + 抓数字"的猜测路线，会把
--   `GT5U.infodata.parallel.current\§e3000000` 里的 `GT5U` 抓成 **5**（3000000 读成 5）。
--   本模块改成"**键优先、标签兜底**"，不猜文本；那个 sensors.lua 已随 v3 重构删除。
--
-- 【必须适配三种输出形态（实机样本）】同一台机器在不同模组版本 / 语言设置下给出完全不同的行，
-- 三种都带 `N = ` 行号前缀：
--
--   A. 未本地化键值（最稳，不受语言影响）
--        1 = GT5U.infodata.purification_unit_base.linked_at\\541\\21\\301
--        2 = GT5U.infodata.purification_unit_base.success_chance\\§e70%§r
--        3 = GT5U.infodata.parallel.current\\§e1
--   B. 中文本地化文本
--        1 = 该净化装置与位于22,8,14的水净化厂相连。
--        2 = 成功几率：§e70%§r
--        3 = 当前并行：§e1
--   C. 英文本地化文本
--        1 = This Purification Unit is linked to the Water Purification Plant at 22, 8, 14.
--        2 = Success chance: §e70%§r
--        3 = Current Parallel: §e1
--
-- 【实测事实（实机）】
--   * 键值形态的分隔符是**双反斜杠** `\\`（个别版本可能是单个），两种都认
--   * **机器停着时 `parallel.current` 会报 1**、`success_chance` 行整行消失
--     -> 并行读数必须由调用方用 `isMachineActive` 做闸门，本模块只负责解析
--   * **值前面带颜色码**（实测是黄色 `§e`）：GT 把"值"染色、标签是别的颜色。
--     并行与成功率两行都是这个形状（`…当前并行：§e3000000` / `…成功几率：§e70%§r`），
--     所以数值的统一取法就是：**关键字之后，第一个带颜色码的数字**（见 coloredNumber）。
--
-- 【依赖】无（连 constants 都不需要）—— 保证任何层都能安全 require
-- 【被谁用】backend/hardware/probes（传感器读数）
--------------------------------------------------------------------------------

local gtInfodata = {}

-- ============================ 字段识别表 ============================
-- 【加字段就在这里加一行】匹配顺序 = 表里的顺序，先命中先算
--   keys    : GT 的未本地化键（子串匹配，大小写不敏感）—— 最稳，优先
--   labels  : 本地化文本里的标签（子串匹配，大小写不敏感；中英都收）—— 兼顾版本差异
--   exclude : 命中这些词就放弃**标签**匹配（键匹配不受影响）
local FIELDS = {
    {
        name    = "parallel",
        keys    = { "parallel.current", "parallel" },
        labels  = { "当前并行", "并行数", "当前并联", "current parallel", "并行", "parallel" },
        -- 排除 GT 的 "Parallel machine count: 5"（讲的是机器数量）；v2 正是把它读成了 5。
        exclude = { "机器", "数量", "machine", "count" }
    },
    {
        name   = "success",
        keys   = { "success_chance", "success" },
        labels = { "成功几率", "成功率", "成功概率", "success chance", "success rate",
            "成功", "success", "chance" }
    }
}

--------------------------------------------------------------------------------
-- 文本预处理
--------------------------------------------------------------------------------

--- 去掉 Minecraft 颜色/样式转义码（§a、§l 等）
-- @param line string
-- @return string
function gtInfodata.stripColors(line)
    return (tostring(line):gsub("§.", ""))
end

--- 去掉行首的"行号前缀"（`1 = ` / `2: ` / `3) ` 等）
-- 三种输出形态都带行号（玩家是从带编号的视图里看的），统一剥掉。
-- 不误伤：数字后面必须紧跟分隔符（= : ： ) .）才算行号（`70%`、`22,8,14` 不满足）。
-- @param line string
-- @return string
function gtInfodata.stripIndex(line)
    return (tostring(line):gsub("^%s*%d+%s*[=:：%)%.]%s*", "", 1))
end

--- 拆分一行为 "键" 与 "值"
-- 两种形态都要认：
--   ① `键\参数...`     —— 实测分隔符是**双反斜杠**（`\\`），故用 `\\+` 匹配"一段反斜杠"
--   ② `键`（无参数）   —— 整行就是一个键，如 `GT5U.infodata.purification_plant.linked_units`
--      判据是"整行只有键字符集（字母/数字/点/下划线）"：纯文本行（如"澄清净化单元: 激活"）
--      含中文/冒号/空格，不会命中；归错会把键当普通文本，丢掉"这个键存在"的信息。
-- ③ 其余（含中文/冒号/空格的普通文本）返回 key = nil，rest = 剥掉行号后的整行。
-- @param line string 原始行
-- @return string|nil key
-- @return string rest 去色码、去行号后的剩余部分（多参数用 " / " 连接）
function gtInfodata.splitLine(line)
    local clean = gtInfodata.stripIndex(gtInfodata.stripColors(line))
    local key, rest = clean:match("^([%w%._]+)\\+(.*)$")
    if key then
        rest = rest:gsub("\\+", " / ")
        return key, (rest:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    -- 无参数键：整行只由键字符集组成
    if clean:match("^[%w%._]+$") then
        return clean, ""
    end
    return nil, clean
end

--------------------------------------------------------------------------------
-- 数值提取
--------------------------------------------------------------------------------

--- 从文本里取第一个**完整**数字（支持 3000000 / 3,000,000 / 5.63e14 / 70% 几种形态）
-- 【先去千位分隔符】`3,000,000` 不去掉的话只能读到第一个 `3`。
--   只删"夹在两位数字之间的逗号"，所以 `22,8,14` 这类坐标不会被粘成一团
--   （而且这类行不会带出任何数值）
-- @param text string|nil
-- @return number|nil
function gtInfodata.firstNumber(text)
    if type(text) ~= "string" then return nil end
    local cleaned = text:gsub("(%d),(%d)", "%1%2")
    local numStr = cleaned:match("([%-%+]?%d+%.?%d*[eE]?[%-%+]?%d*)")
    if not numStr then return nil end
    local num = tonumber(numStr)
    if num == nil then return nil end
    return num
end

--- 取"某个位置之后，第一个**带颜色码**的数字"
-- 本模块唯一的数值取法：**关键字之后，第一个带颜色码的数字**就是目标值
--   （实测 GT 把"值"染色、标签用别的颜色：`3 = 当前并行：§e3000000`）。
-- 颜色码不写死 §e（`…recipesDone.fmt\§a0§r` 是绿色，同样是值）；标签也可能自带颜色
--   （`§b成功几率§7: §e70%`），第一个色码段里没数字就继续往后看。
-- 入参必须是**带色码的原始行**；已去色码的字符串这里什么也找不到。
-- @param text string 原始行
-- @param fromPos number|nil 从哪个字节位置开始找（一般是关键字结束处）；默认 1
-- @return number|nil
function gtInfodata.coloredNumber(text, fromPos)
    if type(text) ~= "string" then return nil end
    local i = fromPos or 1
    while true do
        local pos = text:find("§", i, true)
        if not pos then return nil end
        local seg = text:sub(pos + 3) -- 越过 "§x"（§ 本身占 2 字节）
        local stop = seg:find("§", 1, true)
        if stop then seg = seg:sub(1, stop - 1) end
        local num = gtInfodata.firstNumber(seg)
        if num ~= nil then return num end
        i = pos + 3
    end
end

--------------------------------------------------------------------------------
-- 本地化文本形态的辅助（B/C 两种形态走这里）
--------------------------------------------------------------------------------

--- 在某行里找字段标签，返回**第一个**命中的位置
-- 传小写行：ASCII 大小写不影响字节长度，用同样位置去原串里取值是安全的。
-- 位置来自原行的小写：标签本身不含色码，位置可直接用来"往后取值"。
-- @param lowerLine string 已小写化的行（传原行的小写，位置才对得上 raw）
-- @param labels table 标签表
-- @return number|nil 位置（字节下标）
-- @return number|nil 标签字节长度
local function matchLabel(lowerLine, labels)
    for _, label in ipairs(labels or {}) do
        local needle = label:lower()
        local pos = lowerLine:find(needle, 1, true)
        if pos then return pos, #needle end
    end
    return nil, nil
end

--- 该行是否命中字段的"排除词"（只在标签匹配路径上用）
-- @param lowerLine string
-- @param field table
-- @return boolean
local function excluded(lowerLine, field)
    for _, token in ipairs(field.exclude or {}) do
        if lowerLine:find(token:lower(), 1, true) then return true end
    end
    return false
end

--- 在一行里找字段：① 未本地化键优先（形态 A） ② 本地化标签兜底（形态 B/C）
-- 返回值位置的原因：取值规则是"关键字**之后**第一个带颜色码的数字"，必须知道关键字在
--   **原行**里到哪里结束（标签本身不含色码，直接在小写化的原行上找，位置就是准的）。
-- @param raw string 原始行（带色码）
-- @param plain string 去色码后的行
-- @param key string|nil splitLine 得到的键（nil = 这行不是键值形态）
-- @return table|nil field
-- @return number from 取值的起点（字节位置，在 raw 上）
local function findField(raw, plain, key)
    if key then
        local lowerKey = key:lower()
        for _, field in ipairs(FIELDS) do
            for _, k in ipairs(field.keys) do
                if lowerKey:find(k:lower(), 1, true) then
                    local kpos = raw:find(key, 1, true)
                    return field, (kpos and (kpos + #key) or 1)
                end
            end
        end
        -- 是键、但不是我们要的字段（如 linked_units）：不往下试标签
        return nil, nil
    end

    local lowerRaw = raw:lower()
    local lowerPlain = plain:lower()
    for _, field in ipairs(FIELDS) do
        local pos, len = matchLabel(lowerRaw, field.labels)
        if pos and not excluded(lowerPlain, field) then
            return field, (pos + len)
        end
    end
    return nil, nil
end

--- 取该行"关键字之后"的目标数值
-- 【规则】就是上面那一条：第一个带颜色码的数字。
-- 【唯一例外】整行**一个颜色码都没有**（老格式 / 纯文本输出）时，
--   退回"关键字之后第一个完整数字"；有颜色码但取不到数字就是没有，不再瞎猜。
-- @param raw string 原始行
-- @param from number 关键字结束位置
-- @return number|nil
local function valueAt(raw, from)
    local num = gtInfodata.coloredNumber(raw, from)
    if num ~= nil then return num end
    if raw:find("§", 1, true) then return nil end
    -- 没有色码时 raw 与去色码结果逐字节相同，所以位置可以直接用
    return gtInfodata.firstNumber(raw:sub(from))
end

--- 写入一个字段值
-- 单独包一层：`field.name` 是**动态键**，直接写在 parse 里会被静态分析当成"窄表类型"的
--   已知字段（于是报 number 不能赋给 table|nil）；包一层参数无类型的局部函数最省事。
-- @param info table
-- @param name string
-- @param value any
local function put(info, name, value)
    info[name] = value
end

--------------------------------------------------------------------------------
-- 整段解析
--------------------------------------------------------------------------------

--- 解析一个机器返回的整段传感器文本（三种输出形态都适配，见文件头）
-- @param lines table getSensorInformation() 的返回值（字符串数组；也接受带 \n 的字符串）
-- @return table {
--     parallel    = number|nil  真实并行（机器停着时可能是 1，调用方需自己闸门）
--     success     = number|nil  成功率（原始值，可能是 0~1 或 0~100）
--   }
function gtInfodata.parse(lines)
    local info = {
        parallel = nil,
        success = nil
    }
    if lines == nil then return info end

    -- 允许传"已经拆好的行数组"，也允许传"带 \n 的一整串"
    local list = lines
    if type(lines) == "string" then
        list = {}
        for line in tostring(lines):gmatch("[^\n]+") do list[#list + 1] = line end
    elseif type(lines) ~= "table" then
        return info
    end

    for _, raw in ipairs(list) do
        local plain = gtInfodata.stripColors(raw)

        -- ① 关键字 = 未本地化键（形态 A）或本地化标签（形态 B/C）
        local key = gtInfodata.splitLine(plain)
        local field, from = findField(raw, plain, key)

        -- ② 取值：关键字之后，第一个带颜色码的数字；取不到就当这行没这个字段
        --    （既不是本模块字段、也不是键的纯文本行直接忽略：没有消费者）
        if field then
            local num = valueAt(raw, from)
            if num ~= nil then put(info, field.name, num) end
        end
    end
    return info
end

return gtInfodata
