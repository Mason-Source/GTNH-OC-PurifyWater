--------------------------------------------------------------------------------
-- frontend/viewinput.lua
--------------------------------------------------------------------------------
-- 【职责】**本地视图交互**的唯一实现：图表档位 / 净水状态详情（进·出）/ 退出按钮命中
--   这些动作只改 fstate（不发命令、不碰后端）—— 主端（frontend/input）与镜像端（monitor）共用
-- 【不做什么】不发命令、不取数、不画图
-- 【依赖】frontend/state
-- 【被谁用】frontend/input（主端点击映射）、monitor.lua（镜像端点击处理）
--------------------------------------------------------------------------------

local fstate = require("frontend.state")

local view   = {}

--- 图表标题行的档位按钮：命中则切换档位（0 = 全部）
-- 调用方自己决定怎么刷新（主端 viewmodel.expire；镜像端标脏重画）
-- @param x, y number
-- @return boolean 命中并切换了档位
function view.chartChip(x, y)
    for level, box in pairs(fstate.chartChips or {}) do
        if fstate.hit(box, x, y) then
            fstate.chartLevel = level
            return true
        end
    end
    return false
end

--- 净水状态块：详情态点这块矩形任意处返回；列表态点某一行进该级详情
-- 只认总览页（配置页是整屏面板，坐标会重叠）
-- @param x, y number
-- @return boolean 命中并处理
function view.statusArea(x, y)
    if fstate.currentTab ~= "overview" or not fstate.hit(fstate.areas.status, x, y) then
        return false
    end
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
    return true
end

--- 退出按钮（控制面板最后一行）：主端退主控程序；镜像端退镜像端自己
-- @param x, y number
-- @return boolean
function view.quitButton(x, y)
    return fstate.hit(fstate.buttons.quit, x, y)
end

return view
