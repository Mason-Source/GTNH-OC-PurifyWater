--------------------------------------------------------------------------------
-- backend/hardware/gt_infodata.lua
--------------------------------------------------------------------------------
-- 【职责】解析 GT getSensorInformation() 文本：common(parallel/success) 与按需字段 ph/temperature/controlSignal/lensRequest
-- 【不做什么】不碰组件；并行读数由调用方用 isMachineActive 闸门（停机时报 1）
-- 【依赖】无
-- 【被谁用】backend/hardware/probes
--
-- 适配三种输出形态（A 未本地化键 / B 中文本地化 / C 英文本地化），均带行号前缀。
-- 键值分隔符为一段反斜杠；数值取"关键字之后第一个带颜色码的数字"。
--------------------------------------------------------------------------------

local gtInfodata = {}

-- T6：不同版本分别输出“当前透镜请求”的 key / 本地化标签；只比较整行签名。
local LENS_REQUEST_LABELS = {
    "lens_requested", "lens requested", "current required lens", "required lens",
    "current lens", "当前透镜", "所需透镜", "请求透镜", "需要的透镜"
}

-- ---- 字段识别表 ----
-- keys 键优先，labels 标签兜底（均子串、大小写不敏感）；exclude 命中则放弃标签。
local FIELDS = {
    {
        name    = "parallel",
        keys    = { "parallel.current", "parallel" },
        labels  = { "当前并行", "并行数", "当前并联", "current parallel", "并行", "parallel" },
        -- 排除 "Parallel machine count"（机器数量）
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

--- 去掉行号前缀（1 = / 2: / 3) 等）
-- 数字后必须紧跟分隔符（= : ： ) .）才算行号，避免误伤 70%/坐标。
-- @param line string
-- @return string
function gtInfodata.stripIndex(line)
    return (tostring(line):gsub("^%s*%d+%s*[=:：%)%.]%s*", "", 1))
end

--- 拆分为键与值
-- ① 键\参数 ② 无参数键（整行只有字母/数字/点/下划线）③ 其余文本返回 key=nil。
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

--- 找字段标签，返回第一个命中位置（小写行上，字节位置可回原行用）。
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

--- 找字段：键优先，标签兜底；返回原行上的取值起点。
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

--- 取关键字之后的数值：优先带色码的数字；整行无色码则取第一个完整数字。
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

--- 统一成行数组（兼容字符串输入）
local function toLines(lines)
    if lines == nil then return {} end
    if type(lines) == "string" then
        local out = {}
        for line in tostring(lines):gmatch("[^\n]+") do out[#out + 1] = line end
        return out
    end
    if type(lines) ~= "table" then return {} end
    return lines
end

--- 标签结束位置（在原行 raw 上定位，避免色码改变字节位置）
local function labelEnd(raw, labels)
    local lower = tostring(raw):lower()
    for _, label in ipairs(labels or {}) do
        local pos = lower:find(label:lower(), 1, true)
        if pos then return pos + #label end
    end
    return nil
end

local PH_LABELS = {
    "current ph value", "current ph", "ph value", "ph 值", "当前 ph", "当前ph", "酸碱度"
}
local TEMP_LABELS = {
    "current temperature", "temperature", "当前温度", "温度"
}
local SIGNAL_LABELS = {
    "current control signal", "control signal", "control_signal", "控制信号"
}

--- pH（新版标签 / 旧版 ph\ 键 / 数值后带 pH）
function gtInfodata.ph(lines)
    for _, raw in ipairs(toLines(lines)) do
        local plain = gtInfodata.stripColors(raw)
        local from = labelEnd(raw, PH_LABELS)
        if from then
            local value = valueAt(raw, from)
            if value ~= nil then return value end
        end
        local key = gtInfodata.splitLine(plain)
        if key and key:lower():find("ph", 1, true) then
            local kpos = raw:find(key, 1, true) or 1
            local value = valueAt(raw, kpos + #key)
            if value ~= nil then return value end
        end
        local value = gtInfodata.firstNumber(plain:match("([%-%d%.]+)%s*[pP][hH]"))
        if value ~= nil then return value end
    end
    return nil
end

--- temperature（新版标签 / 旧版 key / 数值后带 K）
function gtInfodata.temperature(lines)
    for _, raw in ipairs(toLines(lines)) do
        local plain = gtInfodata.stripColors(raw)
        local from = labelEnd(raw, TEMP_LABELS)
        if from then
            local value = valueAt(raw, from)
            if value ~= nil then return value end
        end
        local key = gtInfodata.splitLine(plain)
        if key and key:lower():find("temperature", 1, true) then
            local kpos = raw:find(key, 1, true) or 1
            local value = valueAt(raw, kpos + #key)
            if value ~= nil then return value end
        end
        local value = gtInfodata.firstNumber(plain:match("([%-%d%.]+)%s*[kK]"))
        if value ~= nil then return value end
    end
    return nil
end

--- T6 当前请求透镜：返回去色码、去行号、压缩空白后的整行签名
-- 2.8.4: `Current lens requested: Dilithium Lens`
-- 2.9.0: `GT5U.infodata.purification_unit_uv_treatment.lens_requested\\琥珀透镜`
-- @param lines table|string
-- @return string|nil
function gtInfodata.lensRequest(lines)
    for _, raw in ipairs(toLines(lines)) do
        local plain = gtInfodata.stripIndex(gtInfodata.stripColors(raw))
        local lower = plain:lower()
        for _, label in ipairs(LENS_REQUEST_LABELS) do
            if lower:find(label, 1, true) then
                plain = plain:gsub("%s+", " ")
                return (plain:gsub("^%s+", ""):gsub("%s+$", ""))
            end
        end
    end
    return nil
end

--- control signal（0b 二进制 / 旧 control_signal 键 / 标签尾二进制）
function gtInfodata.controlSignal(lines)
    for _, raw in ipairs(toLines(lines)) do
        local plain = gtInfodata.stripColors(raw)
        local bits = plain:match("0[bB]([01]+)")
        if not bits and labelEnd(raw, SIGNAL_LABELS) then
            bits = plain:match("([01]+)%s*$")
        end
        if bits then return tonumber(bits, 2) end
    end
    return nil
end

--- 写入字段值（包一层规避 LuaLS 对动态键的窄表检查）。
-- @param info table
-- @param name string
-- @param value any
local function put(info, name, value)
    info[name] = value
end

--------------------------------------------------------------------------------
-- 整段解析
--------------------------------------------------------------------------------

--- 解析整段传感器文本（三种形态，见文件头）
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

    local list = toLines(lines)

    for _, raw in ipairs(list) do
        local plain = gtInfodata.stripColors(raw)

        -- ① 键或标签定位字段
        local key = gtInfodata.splitLine(plain)
        local field, from = findField(raw, plain, key)

        -- ② 取关键字后的数字；纯文本行忽略
        if field then
            local num = valueAt(raw, from)
            if num ~= nil then put(info, field.name, num) end
        end
    end
    return info
end

gtInfodata.common = gtInfodata.parse

function gtInfodata.parallel(lines)
    return gtInfodata.common(lines).parallel
end

function gtInfodata.success(lines)
    return gtInfodata.common(lines).success
end

local FIELD_PARSERS = {
    parallel      = gtInfodata.parallel,
    success       = gtInfodata.success,
    ph            = gtInfodata.ph,
    temperature   = gtInfodata.temperature,
    controlSignal = gtInfodata.controlSignal,
    lensRequest   = gtInfodata.lensRequest
}

--- 指定字段解析；nil/"common" = parallel+success
function gtInfodata.extract(lines, field)
    if field == nil or field == "common" then return gtInfodata.common(lines) end
    local parser = FIELD_PARSERS[field]
    if not parser then return nil, "unknown sensor field: " .. tostring(field) end
    return parser(lines)
end

return gtInfodata
