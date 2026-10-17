local constants = require("shared.constants")
local utils = {}
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
function utils.formatShortNumber(num)
    if type(num) ~= "number" then return tostring(num) end
    local units = { { "P", 1e15 }, { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "K", 1e3 } }
    for _, u in ipairs(units) do
        if math.abs(num) >= u[2] then return string.format("%.2f%s", num / u[2], u[1]) end
    end
    return tostring(math.floor(num))
end
function utils.shortAddress(address)
    local s = tostring(address or "")
    if s == "" then return "-" end
    return s:sub(1, 8)
end
function utils.sideLabel(side)
    local names = { [0] = "下", [1] = "上", [2] = "北", [3] = "南", [4] = "西", [5] = "东" }
    return names[side] or tostring(side)
end
function utils.normalizeFluidName(name)
    local clean = tostring(name or ""):lower():gsub("^gregtech:", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return clean, "gregtech:" .. clean
end
function utils.keyChar(char)
    if type(char) == "number" then
        if char >= 32 and char <= 126 then return string.char(char):lower() end
        return nil
    end
    if type(char) == "string" and #char == 1 then return char:lower() end
    return nil
end
function utils.isKey(char, code, letter)
    local want = tostring(letter or ""):lower()
    local got  = utils.keyChar(char)
    if got and got == want then return true end
    local codeWant = constants.KEY_CODES[tostring(letter or ""):upper()]
    return codeWant ~= nil and code == codeWant
end
return utils
