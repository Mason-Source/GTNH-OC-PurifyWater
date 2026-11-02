--------------------------------------------------------------------------------
-- PurifyWater/frontend/theme/light.lua
--
-- 定位：浅色主题数据。
-- 配色方法：
-- 1. 参考 Radix Colors 的明度阶梯、Material 3 的 surface container 分层思路，
--    用固定色定义 canvas / menu / chip；内容卡片直接复用 canvas，不再叠加半透明白色。
-- 2. 卡片与底层画布共用填充，仅用结构线分界；透明度只用于交互态与语义叠色。
-- 3. 正文与语义色均按小字号终端阅读校核；交互层以 surface 为基准叠色，便于统一调参。
-- 4. 图表使用同一明度带的深色相，避免浅色主题常见的荧光感和互相粘连。
-- 边界：只提供颜色与角色映射，不含绘制逻辑。
--------------------------------------------------------------------------------

return {
    id = "light",
    label = "浅色",

    color = {
        -- 统一底板：内容卡片与最底层画布同色，只靠 border 勾勒卡片边界。
        canvas = 0xC6CDD4,
        surface = "canvas",
        surfaceAlt = "canvas",

        -- 顶栏层：比卡片明显更深，与正文区域形成稳定的上边界。
        menu = 0x8E9AA8,
        menuMuted = 0x1F2933,
        menuChip = { base = "menu", color = 0xFFFFFF, alpha = 0.22 },
        menuChipActive = { base = "menu", color = 0xFFFFFF, alpha = 0.38 },
        menuChipText = 0x15191E,
        menuChipActiveText = 0x063A62,

        -- 文字层：正文接近黑，次级与禁用态仍保留足够的可读性。
        text = 0x15191E,
        muted = 0x3F4852,
        disabled = 0x535C66,

        -- 语义色：在浅灰底和按钮底上均使用压深版本，避免小字号发虚。
        accent = 0x063A62,
        success = 0x143F1E,
        warning = 0x4F3500,
        danger = 0x6E1919,

        -- 结构线：弱于文字，强于面板，形成不刺眼的终端分隔。
        border = 0x7A838D,
        borderFocus = 0x063A62,
        chartGrid = 0x929BA5,
        chartAxis = 0x535C66,

        -- 状态条：同样以 surface 为基准叠色，语义变化不必重新配一整套底色。
        barTrack = { base = "surface", color = 0x143F1E, alpha = 0.24 },
        barFill = 0x143F1E,
        barEmpty = { base = "surface", color = 0x64748B, alpha = 0.10 },
        cycleTrack = { base = "surface", color = 0x64748B, alpha = 0.16 },
        cycleFill = 0x063A62,

        -- 交互层：按钮与选中态统一从 surface 叠加，透明度直接表达状态强弱。
        chip = { base = "surface", color = 0x475569, alpha = 0.30 },
        chipActive = { base = "surface", color = 0x315A7F, alpha = 0.34 },
        chartChip = { base = "surface", color = 0x64748B, alpha = 0.16 },
        chartChipActive = { base = "surface", color = 0x475569, alpha = 0.30 },
        chipDisabled = { base = "surface", color = 0x64748B, alpha = 0.10 },
        cellSelected = { base = "surface", color = 0x315A7F, alpha = 0.24 },
        chipWarm = { base = "surface", color = 0x4F3500, alpha = 0.20 },
        chipCool = { base = "surface", color = 0x063A62, alpha = 0.20 },
        chipDanger = { base = "surface", color = 0x6E1919, alpha = 0.18 },
    },

    log = {
        error = "danger",
        warn = "warning",
        system = "text",
        diag = "disabled",
    },
    series = { 0x063A62, 0x143F1E, 0x4F3500, 0x4C2E6F, 0x6E1919, 0x07574F, 0x6A4200, 0x7A2348 },
}
