<!-- 本文件由 `build_deploy.py` 从工作区根的 `publish_readme.md` 生成：要改 README 就改那个模板，
     直接改这里的话，下一次 build 会把你改的覆盖掉。 -->

# PurifyWater

GTNH 净水线自动控制程序（OpenComputers）。一台 OC 电脑接上 ME 网络接口、能量仓和各级水厂，
程序自己读水位、测真实并行、算功率、下发开关，把 8 级净水厂的水量维持在你设定的阈值上。

## 特色

- **事件 + 时钟双驱动**：高兼容性，理论支持任意状态启动程序进行连接，旧水厂调度焕新友好。
- **并行靠实测**：并行读数连续 N 个运行周期一致才写入记录；换能源仓、增删单元会让记录自动作废重学。
- **安全优先**：硬件缺失 / 主机总开关关闭 / 开关与调度意图不符 → 停机 + 锁定，**不自动恢复**，
  处理完手动点【启动系统】；锁定期只保留只读逻辑（采集、界面、日志）。
- **数据集中在 `<应用目录>/data/`**：`levels.txt`（阈值 + 勾选，可直接手改）、`records.txt`（实测并行）、
  `history.dat`（曲线）、`settings.txt`、`last_run.txt`（启动退出痕迹与界面错误，排错先看它）。
- **镜像端**：`monitor.lua` 用另一台电脑 + 无线网卡显示同一份快照，不参与调度。

## 目录

| 目录 | 内容 |
|---|---|
| `installer.lua` | **一键安装器**（在 OC 电脑上跑，自动把下面的文件拉全） |
| `PurifyWater/` | **带注释的源码**（要改就改这里） |
| `build/` | 同一份源码**去注释后的版本**，整份丢进 OC 电脑的 `home/` 就能跑 |

## 快速开始

### 一键安装（推荐，需因特网卡）

在 OC 电脑上：

```bash
wget https://raw.githubusercontent.com/Mason-Source/GTNH-OC-PurifyWater/main/installer.lua installer.lua
lua installer.lua
```

装到「当前目录/PurifyWater」，默认拉 `build/`（去注释版）；想要带注释的源码，把 `installer.lua` 开头
`SRC = "build"` 改成 `"PurifyWater"`。装完：

```bash
cd PurifyWater
lua main.lua          # 启动（按 Q 退出）；--debug 打开调度/采样细节
```

安装器**只覆盖清单里的文件**，`data/`（阈值、实测并行、曲线、痕迹）不会被碰 —— 以后更新重跑一遍即可；
但它**不删**上游删掉/改名的旧文件，要干净就先删整个应用目录（记得先备份 `data/`）。

### 手动放置

把 `build/`（或 `PurifyWater/`）整个目录放到 OC 电脑的 `home/` 下：

```bash
cd /home/PurifyWater
lua main.lua              # 控制端（按 Q 退出）
lua main.lua --debug      # 打开 debug 级日志（调度/采样细节）
lua monitor.lua [端口]    # 镜像端（另一台电脑 + 无线网卡，不调度）
```

**首次启动不需要任何配置文件**：`data/levels.txt` 会按「阈值 0 + 全部勾选」自动生成，
此时除"水位见底强制开"外不会开任何一级 —— 先到配置页把各档阈值填上再点【启动系统】。

## 环境

GTNH 2.8.4以上； OpenComputers：T3机箱 T3显示屏 T3APU（=T3CPU+T3显卡） 无线网卡 内存≥2MB（=T3.5内存*2）。

内存实测：**2048K（2MB）才稳** —— 1024K 能启动，但半小时内会崩；曲线与日志已封顶，占地方的是基线本身。
