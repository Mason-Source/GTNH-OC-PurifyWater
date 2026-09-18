--------------------------------------------------------------------------------
-- backend/store/records.lua
--------------------------------------------------------------------------------
-- 【职责】`data/records.txt`（各等级实测并行 + 成功率）的读写与作废
-- 【依赖】backend/store/files、shared/{config,models,constants,state,utils}
-- 【被谁用】main（启动时 load）、app/watch（parallel_write 时 save、硬件变更时作废）
--
-- 【文件】头一行记"写这份记录时的全厂功率"，后面一行一级：
--   `# 功率快照 562949953421312`
--   `1 3000000 70 1234.5`        <- 等级 单台并行 成功率 采样时刻
-- 功率快照：并行上限由能源仓决定，玩家换了能源仓旧并行数字就不可信。
--   启动读回时功率对不上 -> 整份作废（删文件），让系统重新学习（T3 会自动重测）。
--------------------------------------------------------------------------------

local CONFIG    = require("shared.config")
local constants = require("shared.constants")
local models    = require("shared.models")
local state     = require("shared.state")
local utils     = require("shared.utils")
local computer  = require("computer")
local files     = require("backend.store.files")

local records   = {}

local function path()
    return files.path(CONFIG.FILES.RECORDS)
end

--- 功率快照是否匹配（差 0.1% 以内算匹配；state.power.all 为 0 时跳过校验）
-- @param snapshot number|nil
-- @return boolean
local function snapshotMatches(snapshot)
    local now = state.power.all or 0
    if not snapshot or now <= 0 then return true end
    return math.abs(snapshot - now) <= now * 0.001
end

--- 清掉某一级的记录（内存 + 盘）
-- @param level number
local function dropLevel(level)
    local snap = state.plant(level)
    snap.parallel, snap.source = nil, nil
end

--- 启动时读回记录
-- @return boolean 是否读到了可用记录
-- @return string 说明
function records.load()
    if not files.exists(path()) then
        return false, "没有并行记录文件（将按建议值做种子；机器跑起来后连续 3 个运行周期同值才写入实测）"
    end
    local lines = files.readLines(path())

    local snapshot
    for _, line in ipairs(lines) do
        local p = models.powerSnapshot(line)
        if p then
            snapshot = p
            break
        end
    end
    if not snapshotMatches(snapshot) then
        files.remove(path())
        return false, string.format("功率快照不符（记录 %s / 当前 %s），记录已作废",
            utils.formatShortNumber(snapshot or 0), utils.formatShortNumber(state.power.all or 0))
    end

    local count = 0
    for _, line in ipairs(lines) do
        local r = models.record(line)
        if r and type(r.parallel) == "number" and r.parallel > 0 then
            local snap    = state.plant(r.level)
            snap.parallel = r.parallel
            snap.success  = r.success or snap.success
            snap.source   = "measured"
            count         = count + 1
        end
    end
    if count == 0 then return false, "记录文件里没有可用数据" end
    return true, string.format("读回 %d 级并行记录（单台并行）", count)
end

--- 保存（把内存里所有**可信**记录重写一遍；这是盘上唯一的写入路径）
-- @param level number|nil 本次触发的等级
-- @param parallel number|nil 本次写入的单台并行
-- @param success number|nil 本次写入的成功率
-- @return boolean ok
-- @return string 说明
function records.save(level, parallel, success)
    if level and type(parallel) == "number" and parallel > 0 then
        local snap    = state.plant(level)
        snap.parallel = parallel
        snap.success  = success or snap.success
        snap.source   = "measured"
        snap.stamp    = computer.uptime()
    end

    local lines = {
        "# 净水厂并行记录（自动生成：删掉会重新学习）",
        "# 一行一级：等级 单台并行 成功率 采样时刻",
        string.format("# 功率快照 %d", math.floor(state.power.all or 0))
    }
    local count = 0
    for lv = 1, constants.LEVEL_COUNT do
        local snap = state.plant(lv)
        local value = snap.parallel
        if type(value) == "number" and value > 0
            and (snap.source == "measured" or lv == level) then
            lines[#lines + 1] = models.recordLine(lv, value, snap.success, snap.stamp)
            count = count + 1
        end
    end
    local ok, err = files.writeLines(path(), lines)
    if not ok then return false, "写盘失败：" .. tostring(err) end
    return true, string.format("并行记录已写盘（%d 级）", count)
end

--- 标失效：某一级（机器增删）或全部（功率变化）作废，等 T3 重新测
-- @param level number|nil 不传 = 全部
-- @param why string 原因（写日志）
-- @return string 说明
function records.invalidate(level, why)
    if level then
        dropLevel(level)
    else
        for lv = 1, constants.LEVEL_COUNT do dropLevel(lv) end
    end
    local ok = records.save(nil)
    if not ok then return "作废记录后写盘失败" end
    return string.format("%s并行记录已作废（%s），等重新测准",
        level and constants.levelLabel(level) or "全部", tostring(why or "原因未说明"))
end

--- 已有记录的行数（界面/日志用）
-- @return number
function records.count()
    local n = 0
    for lv = 1, constants.LEVEL_COUNT do
        local snap = state.plant(lv)
        if type(snap.parallel) == "number" and snap.parallel > 0
            and snap.source == "measured" then
            n = n + 1
        end
    end
    return n
end

return records
