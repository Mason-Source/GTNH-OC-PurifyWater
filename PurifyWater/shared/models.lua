--------------------------------------------------------------------------------
-- shared/models.lua
--------------------------------------------------------------------------------
-- 【职责】把"原始文本行"变成规范数据 / 变回去（**纯函数**，不读写文件、不碰组件）
-- 【不做什么】不做 IO（那是 backend/store/files），不做判断（那是 domain/*）
-- 【依赖】shared/constants、shared/utils
-- 【被谁用】backend/store/*（文件行 <-> 表）、frontend/viewmodel（显示）
--
-- 盘上两种文件的行格式只在这里定义一次：
--   阈值文件：`level threshold enabled`          例：`3 1000000000000 true`
--   并行记录：`level parallel success stamp`     例：`1 3000000 70 12345.6`
-- 解析与生成成对出现，改格式只改这一处。
--------------------------------------------------------------------------------

local constants = require("shared.constants")
local utils     = require("shared.utils")

local models    = {}

--- 解析阈值文件的一行
-- 容错：行内多余空格、`#` 注释行、enabled 写成 1/0/yes/no 都接受
-- @param line string
-- @return number|nil level
-- @return number|nil threshold
-- @return boolean|nil enabled
function models.levelRule(line)
    local s = tostring(line or ""):gsub("^%s+", "")
    if s == "" or s:sub(1, 1) == "#" then return nil end
    local lv, threshold, enabled = s:match("^(%d+)%s+([%d%.eE%+%-]+)%s*(%S*)")
    lv = tonumber(lv)
    if not lv or lv < 1 or lv > constants.LEVEL_COUNT then return nil end
    local on = true
    local e = tostring(enabled or ""):lower()
    if e == "false" or e == "0" or e == "no" or e == "off" then on = false end
    return lv, tonumber(threshold), on
end

--- 生成阈值文件的一行
-- @param level number
-- @param threshold number
-- @param enabled boolean
-- @return string
function models.levelRuleLine(level, threshold, enabled)
    return string.format("%d %d %s", level, math.floor(tonumber(threshold) or 0),
        enabled and "true" or "false")
end

--- 解析并行记录的一行
-- @param line string
-- @return table|nil { level, parallel, success, stamp }
function models.record(line)
    local s = tostring(line or ""):gsub("^%s+", "")
    if s == "" or s:sub(1, 1) == "#" then return nil end
    local lv, parallel, success, stamp = s:match("^(%d+)%s+(%d+)%s*(%S*)%s*(%S*)")
    lv = tonumber(lv)
    if not lv or lv < 1 or lv > constants.LEVEL_COUNT then return nil end
    return {
        level    = lv,
        parallel = tonumber(parallel),
        success  = tonumber(success),
        stamp    = tonumber(stamp)
    }
end

--- 生成并行记录的一行
-- @param level number
-- @param parallel number
-- @param success number|nil
-- @param stamp number|nil
-- @return string
function models.recordLine(level, parallel, success, stamp)
    return string.format("%d %d %s %s", math.floor(tonumber(level) or 0),
        math.floor(tonumber(parallel) or 0), tostring(success or "-"),
        string.format("%.1f", tonumber(stamp) or 0))
end

--- 解析记录文件头里的功率快照：`# 功率快照 12345`
-- @param line string
-- @return number|nil
function models.powerSnapshot(line)
    local s = tostring(line or "")
    if s:sub(1, 1) ~= "#" then return nil end
    return utils.firstNumber(s)
end

--------------------------------------------------------------------------------
-- 广播快照：接口数据 <-> 文本（无线发出去的、镜像端读回来的都是这一套）
--------------------------------------------------------------------------------
-- OC 的无线消息只能传字符串、单条最多 8192 字节；发端与收端共用这一套格式，改字段只改一处。
-- 【格式】一行一个域，用 `|` 分隔，行首字母是标记：
--   V 版本
--   S 运行|锁定|优先级|主机总开关
--   H 主机|单元|能量仓|缺失清单
--   P 可用功率|已用功率|开着的等级
--   L 等级|台数|开关|在跑台数|水量|阈值|可开|强制|理由
-- 【只送镜像端真正要画的字段】每秒一条、OC 的无线收发与解析都不便宜：L 行从 15 域减到 9 域
--   （8 级就是每帧少 48 个域）；F 行（水位读法）已删（那是调试信息）—— SNAP_VERSION = 6。
-- 文本字段里的 `|` 与换行会被换成 `/`；解析遇到坏行直接跳过。

models.SNAP_VERSION = 6

--- 文本字段清理（分隔符/换行会让整帧解析崩掉）
-- @param value any
-- @return string
local function clean(value)
    return (tostring(value == nil and "-" or value):gsub("[|\r\n]", "/"))
end

--- 数字字段
-- @param value number|nil
-- @return string
local function numOf(value)
    if value == nil then return "-" end
    return tostring(math.floor(tonumber(value) or 0))
end

--- 真值三态：true/false/nil -> "1"/"0"/"-"
-- @param value boolean|nil
-- @return string
local function flagOf(value)
    if value == nil then return "-" end
    return value and "1" or "0"
end

--- 把一个域解析成三态布尔
-- @param s string
-- @return boolean|nil
local function readFlag(s)
    if s == "1" then return true end
    if s == "0" then return false end
    return nil
end

--- 把一行按 `|` 拆开
-- @param line string
-- @return table 数组
local function split(line)
    local out = {}
    for token in tostring(line):gmatch("[^|]*") do out[#out + 1] = token end
    return out
end

--- 快照 -> 文本（发端）
-- @param payload table 形状同 api.snapshot() 的返回
-- @return string
function models.snapshot(payload)
    local lines       = {}
    local hw          = payload.hardware or {}
    local sy          = payload.system or {}
    local pw          = payload.power or {}
    local plan        = payload.plan or {}

    lines[#lines + 1] = table.concat({ "V", models.SNAP_VERSION }, "|")
    lines[#lines + 1] = table.concat({
        "S", flagOf(sy.running), flagOf(sy.locked), clean(sy.priority),
        flagOf((payload.host or {}).switch)
    }, "|")
    lines[#lines + 1] = table.concat({
        "H", numOf(hw.host), numOf(hw.units), numOf(hw.energy),
        clean(table.concat(hw.missing or {}, ","))
    }, "|")
    lines[#lines + 1] = table.concat({
        "P", numOf(pw.all), numOf(pw.used), clean(table.concat(plan.opened or {}, ","))
    }, "|")

    for _, row in ipairs(payload.levels or {}) do
        lines[#lines + 1] = table.concat({
            "L", numOf(row.level), numOf(row.deployed), flagOf(row.switch),
            numOf(row.active), numOf(row.water), numOf(row.rule and row.rule.threshold),
            flagOf(row.openable), flagOf(row.forced), clean(row.reason)
        }, "|")
    end
    return table.concat(lines, "\n") .. "\n"
end

--- 文本 -> 快照（收端；形状与 api.read.* 一致，界面/镜像端可以直接用）
-- @param text string
-- @return table|nil payload
-- @return string|nil 失败原因
function models.parseSnapshot(text)
    local payload = {
        system = {},
        hardware = {},
        power = {},
        plan = { opened = {} },
        levels = {}
    }
    local seen = false

    for line in tostring(text or ""):gmatch("[^\n]+") do
        local f    = split(line)
        local mark = f[1]
        if mark == "V" then
            payload.version = tonumber(f[2]) or 0
            seen            = true
        elseif mark == "S" then
            payload.system = {
                running = readFlag(f[2]),
                locked = readFlag(f[3]),
                priority = f[4]
            }
            payload.host = { switch = readFlag(f[5] or "-") }
        elseif mark == "H" then
            local missing = {}
            if f[5] and f[5] ~= "-" and f[5] ~= "" then
                for name in f[5]:gmatch("[^,]+") do missing[#missing + 1] = name end
            end
            payload.hardware = {
                host = tonumber(f[2]) or 0,
                units = tonumber(f[3]) or 0,
                energy = tonumber(f[4]) or 0,
                missing = missing
            }
        elseif mark == "P" then
            payload.power = {
                all = tonumber(f[2]) or 0,
                used = tonumber(f[3]) or 0
            }
            local opened = {}
            if f[4] and f[4] ~= "-" and f[4] ~= "" then
                for value in f[4]:gmatch("[^,]+") do
                    local level = tonumber(value)
                    if level then opened[#opened + 1] = level end
                end
            end
            payload.plan = { opened = opened }
        elseif mark == "L" then
            local level = tonumber(f[2])
            if level then
                payload.levels[level] = {
                    level = level,
                    deployed = tonumber(f[3]) or 0,
                    switch = readFlag(f[4]),
                    active = tonumber(f[5]),
                    water = tonumber(f[6]),
                    rule = { threshold = tonumber(f[7]) or 0 },
                    openable = readFlag(f[8]),
                    forced = readFlag(f[9]),
                    reason = f[10]
                }
            end
        end
    end

    if not seen then return nil, "不是 v3 快照（缺少版本行）" end
    return payload
end

--- 解析一条分片消息
-- @param message string `v3|<帧号>|<序号>|<总数>|<分片>`
-- @return number|nil 帧号
-- @return number|nil 序号
-- @return number|nil 总数
-- @return string|nil 分片
function models.chunk(message)
    local frame, index, total, part = tostring(message or ""):match("^v3|(%d+)|(%d+)|(%d+)|(.*)$")
    if not frame then return nil end
    return tonumber(frame), tonumber(index), tonumber(total), part
end

return models
