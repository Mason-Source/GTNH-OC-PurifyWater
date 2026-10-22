--------------------------------------------------------------------------------
-- frontend/panels/status.lua
--------------------------------------------------------------------------------
-- 【职责】净水状态格位：平时 8 级 × 2 行；点某级换成该级详情
-- 【不做什么】不拼业务文案（viewmodel 给）；详情画法在 panels/detail
-- 【依赖】frontend/*、shared/constants、unicode
-- 【被谁用】frontend/render
--
-- 详情占本块矩形，切换靠 status 指纹局部重绘；每级两行登记热区。
-- 标题行：状态 + 周期条 + 百分比 + 点击提示；判定理由不上屏。
-- 多台时并行/成功率取最低，不标"最低"；陈旧值标（上次）；矮屏退回每级 1 行。
--------------------------------------------------------------------------------

local unicode       = require("unicode")

local constants     = require("shared.constants")
local fstate        = require("frontend.state")
local theme         = require("frontend.theme")
local widgets       = require("frontend.widgets")
local layout        = require("frontend.layout")
local detail        = require("frontend.panels.detail")

local status        = {}

-- 详情会盖整块矩形；切回列表必须整块重画。
local lastWasDetail = false
--- 一行里的开关/运行文案
-- @param row table
-- @return string
-- @return number 颜色
local function switchText(row)
    if (row.deployed or 0) == 0 then return "未部署", theme.COLORS.TEXT_RED end
    if row.switch == nil then return "读取失败", theme.COLORS.TEXT_RED end
    if row.switch then
        return string.format("开 %s", row.runText), theme.COLORS.TEXT_GREEN
    end
    return string.format("关 %s", row.runText), theme.COLORS.TEXT_YELLOW
end

function status.draw(data)
    -- 详情态：同一块矩形交给 detail 画（热区也归它管，所以先清掉旧的行热区）
    if fstate.detailLevel then
        fstate.levelRows = {}
        lastWasDetail    = true
        return detail.draw(data, fstate.areas.status)
    end

    local area       = fstate.areas.status

    -- 标题行：标题 + 周期条 + 百分比 + 点击提示；窄屏只写百分比。
    local titleY     = area.y + 1
    local hint       = "点某一级看详情 →"
    local label      = "运行周期 "
    local labelX     = area.x + 2 + 12 + 1 -- 标题 "各级净水状态" 12 列 + 1 空格
    local barX       = labelX + unicode.wlen(label)
    local pctW       = 6               -- "100%" / "未运行" 都放得下
    local pctX       = area.x + 2 + (area.w - 4) - unicode.wlen(hint) - 2 - pctW
    local barW       = pctX - barX - 1

    -- ① 框+标题：几何/边框色/刚从详情回来才重画
    --   （frameDirty 时下面几格跟着重画）
    local frameDirty = lastWasDetail or fstate.subDirty("status", "frame", table.concat({ area.x, area.y,
        area.w, area.h, tostring(data.system.priority) }, ":"))
    lastWasDetail    = false
    if frameDirty then
        widgets.drawPanelFrame(area, "各级净水状态", theme.COLORS.TEXT_CYAN,
            theme.borderColor(data.system.priority == "high"))
        if barW >= 8 then
            widgets.drawText(labelX, titleY, label, theme.COLORS.TEXT_DISABLED)
        end
        widgets.drawTextRight(area.x + 2, area.w - 4, titleY, hint, theme.COLORS.TEXT_DISABLED)
    end

    -- ② 周期条+百分比单独一格；指纹按实际填充格数算
    local cycleFp = table.concat({ tostring(data.cycleText),
        tostring(math.floor((data.cycleRatio or 0) * math.max(0, barW))), tostring(barX), tostring(barW) }, ":")
    -- 子指纹先算再判
    local cycleDirty = fstate.subDirty("status", "cycle", cycleFp)
    if frameDirty or cycleDirty then
        if barW >= 8 then
            widgets.drawBar(barX, titleY, barW, data.cycleRatio,
                theme.COLORS.CYCLE_FILL, theme.COLORS.CYCLE_BG)
        end
        widgets.clearArea(pctX, titleY, pctW, 1)
        widgets.drawTextRight(pctX, pctW, titleY, tostring(data.cycleText), theme.COLORS.TEXT_CYAN)
    end

    -- 行位：每级 2 行优先，装不下退回 1 行
    local top    = area.y + 2
    local bottom = area.y + area.h - 2
    local avail  = bottom - top + 1
    local rowH   = (avail >= constants.LEVEL_COUNT * 2) and 2 or 1

    -- 网格列（信息行 3 列 / 进度条行 2 列）——列位只在这里定义一次
    local inner  = { x = area.x + 2, w = area.w - 4 }
    local cols   = layout.cols(inner, { 0.30, 0.24, 0.46 })
    local barCol = layout.cols(inner, { 0.62, 0.38 })

    for level = 1, constants.LEVEL_COUNT do
        local row = data.levels[level]
        local y   = top + (level - 1) * rowH
        if y > bottom then break end

        -- 点击热区：一整行（两行高）= 打开该级详情（本地视图动作，主端/镜像端都登记）
        fstate.levelRows[level]  = { x = area.x, y = y, w = area.w, h = rowH }

        -- ① 名称 + 台数（**等级已经在名称里**："T1澄清"，所以不再重复写一遍 "T1"）
        local name                   = string.format("%s %s", row.label, row.deployText)
        -- ② 勾选 + 开关状态：勾选**始终画**（不藏内容）—— 生效且勾选 = 绿，其余一律灰；
        --   灰着就是"这一列现在不算数"（判据来自 system.effectiveConfig，界面不自己算）
        local switchTxt, switchColor = switchText(row)
        local effective              = (data.system.effectiveConfig or {}).enabled == true
        local mark                   = row.rule.enabled and "[√]" or "[ ]"
        local markColor              = (row.rule.enabled and effective)
            and theme.COLORS.TEXT_GREEN or theme.COLORS.TEXT_DISABLED
        -- ③ 水量（左对齐）+ 成功率（右对齐，占原来水量那个位置；多台时是 T3 汇总的最小值）
        local rateW                  = math.max(4, unicode.wlen(row.rateText))
        local waterW                 = math.max(8, cols[3].w - rateW - 1)
        local waterText              = string.format("水量 %s", row.waterOfText)
        if unicode.wlen(waterText) > waterW then
            waterText = string.format("%s/%s", row.waterText, row.thresholdText)
        end
        if unicode.wlen(waterText) > waterW then
            waterText = unicode.sub(waterText, 1, math.max(1, waterW - 1)) .. "…"
        end

        -- 第二行（水量进度条 + 当前并行-建议并行）：只有 2 行制才画
        local barW2, pText
        if rowH == 2 then
            barW2 = math.max(4, barCol[1].w - 2)
            -- 没在跑 -> 这两个"当前"值是上次运行留下的，各标一个 (上次)（不清零）
            local stale = row.sampleStale and row.sample ~= nil and "（上次）" or ""
            pText = ((row.deployed or 0) == 0) and "并行 -"
                or string.format("并行 %s%s / 建议 %s", row.sampleText, stale, row.suggestText)
        end

        -- 【这一级自己一格】指纹 = 这一格画出来的每一样东西（含坐标；换行位也要重画）
        local rowFp = table.concat({
            y, rowH, name, switchTxt, mark, tostring(data.system.mode),
            tostring(data.system.enforceThreshold), tostring(effective),
            tostring(row.running), tostring(row.rule.enabled),
            waterText, row.rateText,
            tostring(barW2 or ""), tostring((rowH == 2) and math.floor((row.ratio or 0) * barW2) or ""),
            pText or ""
        }, ":")

        local rowDirty = fstate.subDirty("status", "row" .. level, rowFp)
        if frameDirty or rowDirty then
            -- 只清这一级那两行（清多了就等于整块重画）
            widgets.clearArea(inner.x, y, inner.w, rowH)

            widgets.drawText(cols[1].x, y, name,
                row.running and theme.COLORS.TEXT or theme.COLORS.TEXT_DISABLED)
            -- 勾选框占 3 列，后面紧跟开关状态（不留空档：[√]开 3/3）
            widgets.drawText(cols[2].x, y, mark, markColor)
            widgets.drawText(cols[2].x + 3, y, switchTxt, switchColor)
            widgets.drawText(cols[3].x, y, waterText, theme.COLORS.TEXT)
            widgets.drawTextRight(cols[3].x, cols[3].w, y, row.rateText, theme.COLORS.TEXT_CYAN)

            if rowH == 2 then
                -- 水量进度条（只画条，不叠字）：填了=浅绿底+绿进度，全空=浅红底
                -- 【配色与“全空判据”都在 widgets.drawBar / theme.COLORS.BAR_* 里，这里一个颜色都不传】
                widgets.drawBar(barCol[1].x, y + 1, barW2, row.ratio)
                widgets.drawTextRight(barCol[2].x, barCol[2].w, y + 1, pText, theme.COLORS.TEXT_CYAN)
            end
        end
    end
end

--- 指纹（**面板级开关**）：指纹没变就整块不画；子区域的指纹再决定"这一块里哪几格重画"。
-- 【必须盖住子区域】面板级指纹要是漏了某样东西，子区域就等于永远不会被评估
--   -> 那一格永远不更新（比多画几次严重得多）。这里比子区域更"宽"：
--   barCells 按百分比粒度，格数变必跟变。
-- detailLevel 必须进指纹：详情态与列表态是同一格位的两套内容，切换要触发局部重画。
-- priority 决定边框色（高级水优先 = 红框）：
--   指纹不含它就等于“画了红框但不知道红框算自己的一部分”，切换时边框不会变。
-- mode / enforceThreshold 决定勾选框的灰亮（生效与否）：**面板级**指纹漏了它们，draw 根本不会被调用，
--   行级指纹再准也没机会重画。
function status.fingerprint(data)
    if fstate.detailLevel then
        return "detail\x1f" .. detail.fingerprint(data)
    end
    local parts = { tostring(data.system.priority), tostring(data.system.mode),
        tostring(data.system.enforceThreshold),
        tostring(data.cycleText), tostring(math.floor((data.cycleRatio or 0) * 100)),
        tostring(fstate.areas.status and fstate.areas.status.h or 0),
        tostring(fstate.areas.status and fstate.areas.status.w or 0) }
    for level = 1, constants.LEVEL_COUNT do
        local row         = data.levels[level]
        parts[#parts + 1] = table.concat({
            row.deployed, row.switchText, row.runText, row.waterText, row.thresholdText,
            row.sampleText, tostring(row.sampleStale), row.suggestText, row.rateText,
            tostring(math.floor((row.ratio or 0) * 100)),
            tostring(row.rule.enabled), tostring(row.running)
        }, ":")
    end
    return table.concat(parts, "\x1f")
end

return status
