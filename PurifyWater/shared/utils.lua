--------------------------------------------------------------------------------
-- shared/utils.lua
--------------------------------------------------------------------------------
-- 【职责】纯函数工具箱：数字格式化、GT 文本取值、流体名归一化、深拷贝、按键判据
-- 【不做什么】不读组件、不读文件、不碰 state —— 全是"输入 -> 输出"
-- 【依赖】shared/constants
-- 【被谁用】各层；数值取法 firstNumber 由传感器解析、阈值文件解析、界面显示共用
--------------------------------------------------------------------------------

local constants = require("shared.constants")

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

--- 取第一个**完整**数字（认 3000000 / 3,000,000 / 5.63e14 / 70%）
-- 千位分隔符先并回数字，否则 `3,000,000` 只会读到 3；只并夹在两位数字之间的逗号，
-- 坐标串 `22,8,14` 不受影响。
-- @param text string|nil
-- @return number|nil
function utils.firstNumber(text)
    if type(text) ~= "string" then return nil end
    local cleaned = text:gsub("(%d),(%d)", "%1%2")
    local numStr = cleaned:match("([%-%+]?%d+%.?%d*[eE]?[%-%+]?%d*)")
    if not numStr then return nil end
    return tonumber(numStr)
end

--- 归一化流体名：返回（去前缀小写名, 补全的完整名）
-- @param name string
-- @return string clean
-- @return string full
function utils.normalizeFluidName(name)
    local clean = tostring(name or ""):lower():gsub("^gregtech:", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return clean, "gregtech:" .. clean
end

--- 把 `key_down` 的 char 载荷变成单个小写字符
-- `key_down` 的 char 载荷是**数字（ASCII 码）**而不是字符：`tostring(char) == "q"` 恒为假
-- （`tostring(113)` = `"113"`）。
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

--- 是否按了某个字母键：**认两种判据** —— 字符（char）或扫描码（code）
-- 某些键盘布局/修饰键下 char 可能是 0，扫描码不受影响，所以两个都试。
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
