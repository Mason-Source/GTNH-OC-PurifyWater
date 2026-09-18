--------------------------------------------------------------------------------
-- frontend/state.lua
--------------------------------------------------------------------------------
-- 【职责】**前端自己的状态**：分辨率、网格、布局矩形、当前页、热区、编辑态、gpu 引用
-- 【不做什么】不存任何业务数据（业务数据一律 `api.read.*` 现取）——这条是前后端分离的关键
-- 【依赖】无（纯状态容器）
-- 【被谁用】frontend/*（全部）
--
-- 【重绘模型】谁变谁重绘，分两级：
--   ① **面板级指纹**（render.lua）：指纹没变就不调这个面板的 draw；
--   ② **面板内的子区域指纹**（fstate.subDirty）：面板要画时，只有真变了的那一格重画
--      （日志的行区 / 状态面板的每级那两行 + 周期条）—— “总有一小块在动”的面板就不会每帧整块清底，
--      屏幕也就不闪了。
--   数据变化由指纹自动发现，不需要任何全局脏标记；只有版面结构变了（切页 / 改分辨率）才整屏重画。
--   ⚠ 不变式：**面板级指纹必须是子区域指纹的超集** —— 面板级漏了某样东西，那一格的子指纹就
--   永远不会被评估 -> 永远不更新（比多画几次严重得多）。
--------------------------------------------------------------------------------

local fstate = {
    -- 组件代理（boot 时赋值；OC 的 gpu 代理没法在这里写全类型，故标 any）
    ---@type any
    gpu            = nil,
    W              = 0,
    H              = 0,                        -- 当前分辨率
    grid           = { rows = {}, cols = {} }, -- **网格**：布局的唯一坐标来源（layout 填）
    areas          = {},                       -- 由网格派生：{ tabBar=, control=, status=, chart=, log=, config=, editline=, keypad= }
    currentTab     = "overview",               -- "overview" | "config"（详情不是页：它只是 status 面板换内容）
    tabs           = {},                       -- 页签热区 { [name] = { x, y, w, h } }
    buttons        = {},                       -- 按钮热区 { [name] = { x, y, w, h, action, label } }
    levelRows      = {},                       -- 净水状态面板：每级那一行（两行高）的点击热区 { [level] = box }
    detailLevel    = nil,                      -- 非 nil = 净水状态面板正显示这一级的详情（点任意处返回）
    chartLevel     = 0,                        -- 0 = 全部（柱状图）｜ 1..8 = 单级（2 游戏日曲线）
    chartChips     = {},                       -- 图表标题行的等级按钮热区 { [level] = {x,y,w,h} }，level 0 = 全部
    logTitle       = nil,                      -- 日志面板标题热区（点它切 user/debug）
    -- 配置页：点某级选中它 -> 用常驻虚拟键盘改阈值（物理键盘不输入）
    configRows     = {},                       -- 每级那一行的点击热区 { [level] = box }
    checkCells     = {},                       -- 勾选格热区 { [level] = box }（点它只切勾选，不算选中）
    keyCells       = {},                       -- 虚拟键盘热区（数组；每项带 kind/value，语义在 input）
    configSel      = nil,                      -- 选中的等级（1..8；nil = 未选中）
    configBuf      = nil,                      -- 输入缓冲：**纯数字串**（kL），不带逗号不带单位
    lastData       = nil,                      -- 本帧视图数据（input 编辑时要读"当前值"）
    baseResolution = nil,                      -- 程序启动前的分辨率（退出时还原，见 render.restoreResolution）
    render         = { fingerprints = {}, forceAll = true, subs = {} }
}

--- 面板**内部**的子区域指纹（面板级指纹只管"这个面板要不要重画"）
-- 为什么两层：像状态面板、日志这种"总有一小块在动"的面板，面板级指纹必然每次都变
--   -> 整块清底重画 -> 屏幕上就是闪。子区域让**真正变了的那一格**单独重画。
-- 用法：画之前 `if fstate.subDirty("status", "row3", fp) then ... end`
--   fp 必须盖住这一格画的**每一样输入**（含坐标：位置变了也得重画）。
-- @param panel string 面板名（与 render.PANELS 的表键一致，避免不同面板撞名）
-- @param sub string 子区域名
-- @param fp any 该子区域这一帧的指纹（会当字符串比）
-- @return boolean 需不需要画
function fstate.subDirty(panel, sub, fp)
    local subs = fstate.render.subs[panel]
    if not subs then
        subs = {}
        fstate.render.subs[panel] = subs
    end
    local key = tostring(fp)
    if subs[sub] == key then return false end
    subs[sub] = key
    return true
end

--- 清掉全部子区域指纹（整屏重画时必须调：不清就等于"以为画过了"）
function fstate.clearSubs()
    fstate.render.subs = {}
end

--- 整屏重画（切页 / 改分辨率 / 改字体）
-- 唯一的强制重绘入口：不提供"单面板失效"接口 —— 数据一变，面板指纹自己就变了。
function fstate.invalidateAll()
    fstate.render.forceAll = true
end

--- 清空所有热区（布局变化时必须清，否则会点到旧坐标）
function fstate.clearHitboxes()
    fstate.buttons, fstate.tabs, fstate.chartChips = {}, {}, {}
    fstate.checkCells, fstate.configRows, fstate.keyCells = {}, {}, {}
    fstate.levelRows = {}
    fstate.logTitle = nil
end

--- 命中测试
-- @param box table|nil { x, y, w, h }
-- @param x, y number
-- @return boolean
function fstate.hit(box, x, y)
    if not box then return false end
    return x >= box.x and x < box.x + box.w and y >= box.y and y < box.y + box.h
end

--- 找出点中的按钮
-- @param x, y number
-- @return string|nil 按钮名
-- @return table|nil 热区
function fstate.buttonAt(x, y)
    for name, box in pairs(fstate.buttons) do
        if fstate.hit(box, x, y) then return name, box end
    end
    return nil, nil
end

return fstate
