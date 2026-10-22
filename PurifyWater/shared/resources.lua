--------------------------------------------------------------------------------
-- shared/resources.lua
--------------------------------------------------------------------------------
-- 【职责】物品 / 流体资源注册名、damage、显示名的唯一真源
-- 【不做什么】不含机器 / 组件、等级映射、数量、配方或业务逻辑
-- 【依赖】无
-- 【被谁用】shared/constants、backend/domain/produce/*
-- 【维护】GTNH 资源名或显示名变化时只改本文件；等级/机器/组件映射不在这里
--------------------------------------------------------------------------------

local resources = {}

resources.FLUIDS = {
    -- 净化水；等级映射在 shared/constants.FLUID_NAMES
    PURIFIED_WATER_1 = { id = "grade1purifiedwater", label = "一级净化水" },
    PURIFIED_WATER_2 = { id = "grade2purifiedwater", label = "二级净化水" },
    PURIFIED_WATER_3 = { id = "grade3purifiedwater", label = "三级净化水" },
    PURIFIED_WATER_4 = { id = "grade4purifiedwater", label = "四级净化水" },
    PURIFIED_WATER_5 = { id = "grade5purifiedwater", label = "五级净化水" },
    PURIFIED_WATER_6 = { id = "grade6purifiedwater", label = "六级净化水" },
    PURIFIED_WATER_7 = { id = "grade7purifiedwater", label = "七级净化水" },
    PURIFIED_WATER_8 = { id = "grade8purifiedwater", label = "八级净化水" },

    -- T3
    POLYALUMINIUM_CHLORIDE = { id = "polyaluminiumchloride", label = "聚氯化铝" },

    -- T4
    HYDROCHLORIC_ACID = { id = "hydrochloricacid_gt5u", label = "氢氯酸" },

    -- T5 / T7
    HELIUM_PLASMA = { id = "plasma.helium", label = "氦等离子" },
    SUPERCOOLANT  = { id = "supercoolant", label = "超级冷却液" },

    -- T7
    HELIUM          = { id = "helium", label = "氦" },
    NEON            = { id = "neon", label = "氖" },
    KRYPTON         = { id = "krypton", label = "氪" },
    XENON           = { id = "xenon", label = "氙" },
    MOLTEN_NEUTRONIUM = { id = "molten.neutronium", label = "熔融中子" },

    -- T7 熔融超导粗胚候选
    MOLTEN_SUPERCONDUCTOR_UV  = { id = "molten.longasssuperconductornameforuvwire", label = "熔融超导粗胚（UV）" },
    MOLTEN_SUPERCONDUCTOR_UHV = { id = "molten.longasssuperconductornameforuhvwire", label = "熔融超导粗胚（UHV）" },
    MOLTEN_SUPERCONDUCTOR_UEV = { id = "molten.superconductoruevbase", label = "熔融超导粗胚（UEV）" },
    MOLTEN_SUPERCONDUCTOR_UIV = { id = "molten.superconductoruivbase", label = "熔融超导粗胚（UIV）" },
    MOLTEN_SUPERCONDUCTOR_UMV = { id = "molten.superconductorumvbase", label = "熔融超导粗胚（UMV）" }
}

resources.ITEMS = {
    -- T4
    SODIUM_HYDROXIDE_DUST = {
        name   = "gregtech:gt.metaitem.01",
        damage = 2685,
        label  = "氢氧化钠粉"
    },

    -- T6 透镜
    LENS_SYNTHETIC_JADE = {
        name   = "bartworks:gt.bwMetaGeneratedlens",
        damage = 10023,
        label  = "合成玉透镜"
    },
    LENS_AMBER = {
        name   = "gregtech:gt.metaitem.01",
        damage = 24514,
        label  = "琥珀透镜"
    },
    LENS_WIND_MAGIC_CRYSTAL = {
        name   = "gregtech:gt.metaitem.01",
        damage = 24540,
        label  = "风之魔晶透镜"
    },
    LENS_EMERALD = {
        name   = "gregtech:gt.metaitem.01",
        damage = 24501,
        label  = "绿宝石透镜"
    },
    LENS_MAGIC_DIAMOND = {
        name   = "gregtech:gt.metaitem.01",
        damage = 24208,
        label  = "魔力钻石透镜"
    },
    LENS_BLUE_TOPAZ = {
        name   = "gregtech:gt.metaitem.01",
        damage = 24513,
        label  = "蓝黄玉透镜"
    },
    LENS_AMETHYST = {
        name   = "gregtech:gt.metaitem.01",
        damage = 24509,
        label  = "紫水晶透镜"
    },
    LENS_FLUORINE_IRON_TOURMALINE = {
        name   = "bartworks:gt.bwMetaGeneratedlens",
        damage = 5,
        label  = "氟铁电气石透镜"
    },
    LENS_DILITHIUM = {
        name   = "gregtech:gt.metaitem.01",
        damage = 24515,
        label  = "双锂透镜"
    },

    -- T8 夸克释放催化剂
    QUARK_UP_CATALYST = {
        name   = "gregtech:gt.metaitem.03",
        damage = 32235,
        label  = "上夸克释放催化剂"
    },
    QUARK_DOWN_CATALYST = {
        name   = "gregtech:gt.metaitem.03",
        damage = 32236,
        label  = "下夸克释放催化剂"
    },
    QUARK_STRANGE_CATALYST = {
        name   = "gregtech:gt.metaitem.03",
        damage = 32237,
        label  = "奇夸克释放催化剂"
    },
    QUARK_CHARM_CATALYST = {
        name   = "gregtech:gt.metaitem.03",
        damage = 32238,
        label  = "粲夸克释放催化剂"
    },
    QUARK_BOTTOM_CATALYST = {
        name   = "gregtech:gt.metaitem.03",
        damage = 32239,
        label  = "底夸克释放催化剂"
    },
    QUARK_TOP_CATALYST = {
        name   = "gregtech:gt.metaitem.03",
        damage = 32240,
        label  = "顶夸克释放催化剂"
    }
}

return resources
