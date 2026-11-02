--------------------------------------------------------------------------------
-- PurifyWater/frontend/ui/components/log.lua
--
-- 定位：日志面板组件。
-- 功能：按宽度折行、保留可视尾部，并根据日志 kind 选择主题色。
-- 边界：只显示已格式化日志，不读取或写入日志文件。
--------------------------------------------------------------------------------

local unicode = require("unicode")
local Component = require("frontend.ui.base")
local LogPanel = {}

--- 创建日志面板组件。
function LogPanel.new()
    local self = Component.new("log", { entries = {} })
    self.prepare = LogPanel.prepare
    self.fingerprint = LogPanel.fingerprint
    self.render = LogPanel.render
    self._wrapKey = nil
    self._wrapped = {}
    return self
end

local function wrapLine(text, width)
    local lines, current = {}, ""
    for index = 1, unicode.len(text) do
        local char = unicode.sub(text, index, index)
        if unicode.wlen(current .. char) > width then
            lines[#lines + 1] = current
            current = char
        else
            current = current .. char
        end
    end
    lines[#lines + 1] = current
    return lines
end

--- 在布局变化时更新日志折行缓存。
function LogPanel:prepare()
    local width = math.max(1, self.rect.w - 4)
    local view = self.props.log or {}
    local revision = tonumber(view.revision) or 0
    local key = tostring(revision) .. ":" .. tostring(width)
    if self._wrapKey == key then return end

    local wrapped = {}
    for _, entry in ipairs(view.entries or {}) do
        local text = tostring(entry.text or "")
        for line in (text .. "\n"):gmatch("(.-)\n") do
            local pieces = wrapLine(line, width)
            for _, piece in ipairs(pieces) do
                wrapped[#wrapped + 1] = {
                    text = piece,
                    kind = entry.kind or "info",
                    seq = entry.seq,
                }
            end
        end
    end

    self._wrapKey = key
    self._wrapped = wrapped
end

--- 生成日志内容和尺寸的渲染指纹。
function LogPanel:fingerprint(context)
    self:prepare()
    return table.concat({
        self.key,
        self.rect.x, self.rect.y, self.rect.w, self.rect.h,
        context.themeId,
        self._wrapKey,
    }, "\x1f")
end

--- 绘制可视尾部日志。
function LogPanel:render(context)
    local p = context.painter
    local r = self.rect
    self:prepare()

    p:panel(r, "系统日志")
    local rows = math.max(0, r.h - 2)
    if rows == 0 then return end

    p:fill({ x = r.x + 1, y = r.y + 1, w = r.w - 2, h = rows }, "surface")

    local total = #self._wrapped
    if total == 0 then
        p:text(r.x + 2, r.y + 1, "暂无日志", "muted", "surface", r.w - 4)
        return
    end

    local start = math.max(1, total - rows + 1)
    local y = r.y + 1
    for index = start, math.min(total, start + rows - 1) do
        local line = self._wrapped[index]
        local role = context.theme.log[line.kind] or "text"
        p:text(r.x + 2, y, line.text, role, "surface", r.w - 4)
        y = y + 1
    end
end

return LogPanel
