--------------------------------------------------------------------------------
-- shared/utils.lua
--------------------------------------------------------------------------------
-- 【职责】纯函数：数字格式化、文本宽度截断、流体名归一化、按键判据
-- 【不做什么】不读组件/文件/state
-- 【依赖】shared/constants、unicode
-- 【被谁用】各层格式化、frontend/input、hardware
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local unicode   = require("unicode")

local utils = {}

--- 千分位：1234567 -> "1,234,567"
-- @param num number|nil
-- @return string
function utils.formatNumber(num)
    if type(num) ~= "number" then return tostring(num) end
    local s = tostring(math.floor(num))
    local sign = s:sub(1, 1) == "-" and "-" or ""
    if sign == "-" then s = s:sub(2) end
    local out = {}
    while #s > 3 do
        table.insert(out, 1, s:sub(-3))
        s = s:sub(1, #s - 3)
    end
    table.insert(out, 1, s)
    return sign .. table.concat(out, ",")
end

--- 短单位：1234567 -> "1.23M"（K / M / G / T / P）
-- @param num number|nil
-- @return string
function utils.formatShortNumber(num)
    if type(num) ~= "number" then return tostring(num) end
    local units = { { "P", 1e15 }, { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "K", 1e3 } }
    for _, u in ipairs(units) do
        if math.abs(num) >= u[2] then return string.format("%.2f%s", num / u[2], u[1]) end
    end
    return tostring(math.floor(num))
end

--- 短地址（日志 / 界面用；取前 8 位）
-- @param address string|nil
-- @return string
function utils.shortAddress(address)
    local s = tostring(address or "")
    if s == "" then return "-" end
    return s:sub(1, 8)
end

--- 侧位中文名（OC 方向编号：0 下 / 1 上 / 2 北 / 3 南 / 4 西 / 5 东）
-- @param side number|nil
-- @return string
function utils.sideLabel(side)
    local names = { [0] = "下", [1] = "上", [2] = "北", [3] = "南", [4] = "西", [5] = "东" }
    return names[side] or tostring(side)
end

--- 按显示宽度截断，超出时加省略号
-- @param value any
-- @param maxWidth number|nil
-- @return string
function utils.truncate(value, maxWidth)
    local source = tostring(value or "")
    maxWidth = math.max(1, math.floor(tonumber(maxWidth) or unicode.wlen(source)))
    if unicode.wlen(source) <= maxWidth then return source end

    local suffix = "…"
    local limit  = math.max(0, maxWidth - unicode.wlen(suffix))
    local out, width = {}, 0
    for index = 1, unicode.len(source) do
        local char = unicode.sub(source, index, index)
        local charWidth = unicode.wlen(char)
        if width + charWidth > limit then break end
        out[#out + 1] = char
        width = width + charWidth
    end
    return table.concat(out) .. suffix
end

--- 拼接文本并按显示宽度截断
-- @param values table|nil
-- @param maxWidth number|nil
-- @param separator string|nil
-- @return string
function utils.joinLimited(values, maxWidth, separator)
    local out = {}
    for index, value in ipairs(values or {}) do out[index] = tostring(value) end
    return utils.truncate(table.concat(out, separator or "、"), maxWidth)
end

--- 归一化流体名：返回（去前缀小写名, 补全的完整名）
-- @param name string
-- @return string clean
-- @return string full
function utils.normalizeFluidName(name)
    local clean = tostring(name or ""):lower():gsub("^gregtech:", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return clean, "gregtech:" .. clean
end

--- 成功率归一化：0～1 -> 0～100；其余原样转数字
-- @param value any
-- @return number|nil
function utils.toPercent(value)
    local num = tonumber(value)
    if num == nil then return nil end
    return num <= 1 and num * 100 or num
end

--- key_down 的 char 载荷 -> 单个小写字符
-- char 是 ASCII 码数字，不是字符。
-- @param char number|string|nil
-- @return string|nil 单个小写字符（不是可打印 ASCII 时返回 nil）
function utils.keyChar(char)
    if type(char) == "number" then
        if char >= 32 and char <= 126 then return string.char(char):lower() end
        return nil
    end
    if type(char) == "string" and #char == 1 then return char:lower() end
    return nil
end

--- 是否按了某字母键：字符或扫描码双判据。
-- 部分布局 char 可能为 0，扫描码不受影响，故两者都试。
-- @param char number|string|nil `key_down` 的 ev[3]
-- @param code number|nil `key_down` 的 ev[4]
-- @param letter string 单个字母，如 "q" / "r"
-- @return boolean
function utils.isKey(char, code, letter)
    local want = tostring(letter or ""):lower()
    local got  = utils.keyChar(char)
    if got and got == want then return true end
    local codeWant = constants.KEY_CODES[tostring(letter or ""):upper()]
    return codeWant ~= nil and code == codeWant
end

return utils
