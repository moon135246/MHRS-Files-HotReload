# 怪物猎人：崛起／曙光 · 外观热加载

在游戏运行时安装、修改或卸载外观 MOD，当前猎人的防具、材质和贴图会随文件更新。村庄、训练场和单人任务都可以使用，持武器、瞄准或移动时也能刷新防具。

**当前版本 1.1.0**　[下载安装包](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.1.0.zip) · [历史版本](https://github.com/moon135246/MHRS-Files-HotReload/releases)

## 使用方法（MOD 玩家）

1. 安装崛起版 REFramework，退出游戏。使用普通外观或原装 Lua Bone System 时开启 **LooseFileLoader**。使用 FirstNatives 时关闭该选项，由 FirstNatives 加载文件。
2. 把 `MHRS-Files-HotReload-v1.1.0.zip` 拖入 Fluffy，在 **Monster Hunter Rise** 中启用。手动安装时，把 ZIP 里的 `reframework` 文件夹合并到游戏根目录。
3. 启动游戏，照常安装、替换或卸载 `natives/stm` 下的外观文件。外观需要的自定义材质模板仍由对应 MOD 或前置提供。

从 1.0.0 升级时，先在 Fluffy 停用旧版，并退出手动启动的监听器。手动安装的旧版还需移出其 Lua 入口、`MHRS_HotReload` 脚本目录和辅助程序。

## 使用方法（MOD 作者）

- 保存正在使用的模型、材质、贴图或动作文件即可看效果。删除松散覆盖后，支持回退的资源会从本机游戏 PAK 重新读取。
- 从 `reframework/data/MHRS-Files-HotReload/watcher.log` 查看监听状态和缺失依赖。补齐缺少的 MMTR 或 TEX 后，对应装备会自动重试。

[构建与材质验证](docs/material-reload.md) · [18 类资源的替换与回退](docs/reentry-18.md) · [骨架与穿戴物理](docs/worn-skeletons.md)

## 更新记录

| 版本 | 本版更新 |
| --- | --- |
| [1.1.0](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.1.0) | 单件与整套防具按当前挂点刷新，贴图、模板就绪后分组更新。 |
| [1.0.9](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.9) | 修复开场演出结束后仍无法换装的问题，换场后重新匹配装备。 |
| [1.0.8](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.8) | 记录缺失的 MMTR 路径，补装模板后继续换装。 |
| [1.0.7](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.7) | 拔刀、瞄准和移动时都可刷新防具。 |
| [1.0.6](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.6) | 保留武器、副件和染色，在原挂点更新五件防具。 |
| [1.0.5](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.5) | 只修改顶点且布局相同时，直接更新当前模型。 |
| [1.0.4](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.4) | 整套外观可以在训练场和进行中的单人任务里刷新。 |
| [1.0.3](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.3) | 适配原装 Lua Bone System，保存姿态 JSON 即可更新装备。 |
| [1.0.2](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.2) | 在村庄换装时一并更新骨架和防具物理。 |
| [1.0.1](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.1) | 改为单 DLL 安装，游戏启动后首次添加外观即可刷新。 |
| [1.0.0](https://github.com/moon135246/MHRS-Files-HotReload/releases/tag/v1.0.0) | 支持 18 类游戏资源的热加载。 |

## 村内资源实测

验证环境为 Windows x64、Steam 版《怪物猎人：崛起》16.0.2.0（Build 17920865）及 REFramework c4b13148。

| 资源 | 村内实机测试 |
| --- | --- |
| `.chain.48` | 手甲的活动组数和资源组数均完成 15 → 14 → 15。保存 `npc018.chain.48` 后，共用它的两个活动 NPC 的物理组数同步完成 4 → 3 → 4。 |
| `.jcns.21` | 保存 `f_wst279_drv.jcns.21` 后，当前腰甲的关节约束层输出目标数完成 4 → 11 → 4。四个使用 `npc016_00_body_drv.jcns.21` 的 NPC 同步完成 12 → 11 → 12，一个使用艾露猫公共约束 `otomo000_body_drv.jcns.21` 的场景对象完成 8 → 7 → 8。 |
| `.motbank.3` | 保存 `npc018_00_bank.motbank.3` 后，村民动作组件中的活动 BankID 列表完成 `[0,10] → [0,11] → [0,10]`。已验证主动作库绑定和活动编号，尚未验证动作片段播放效果。 |
| `.mesh.2109148288` | 修改手甲顶点后，同一 Mesh 组件换用新资源，画面出现位移。恢复后模型再次就绪。 |
| `.tex.28` | 单独覆盖 `moon_5.tex.28`，手甲的两个使用槽同步变为洋红色，恢复后两槽再次绑定原路径的新资源。 |
| `.rtex.5.stm` | 加工店头巾小窗实际使用 `PreviewCamera_ObjMini.rtex`。单独覆盖时预览分辨率降至 95×64，删除后恢复 680×512，头巾区域逐像素恢复。 |
| `.mmtr.220427553` | 支持同一透明模板被多个活动 MDF 共用。监听器用松散文件或 `--baseline-root` 中的原件检查参数偏移、宽度、缓冲区大小和贴图槽。所有匹配的 MDF 就绪后在同一帧绑定。已在 279 手甲和头盔验证透明模板覆盖、恢复和中途失败回滚。 |
| `.user.2` | 按文件差异写入头盔的 `PlayerUserDataPartsHelm` 实例。实测 `FullFace`、`HairChainStop` 和 `HairShapeData[0]` 可修改并恢复。验证的是实例字段读数。外观或模拟下次何时使用各字段，取决于游戏的消费时机。支持现有头发与脸部记录、相同数组长度及空的 `_ChainChangeList`。 |
| `.mdf2.23` | 原路径整份材质替换。手甲的冷贴图引用与恢复结果见下节。 |
| `.efx.2818730` | 已启动的 EffectPlayer 跨帧绑定新资源并重新播放。当前角色 `effect_player00` 的任务数和发射器数都完成 4 → 2 → 4。另测得只保存被引用的冷路径 UVS 即可触发正在播放的玩家 EFX 重载。 |
| `.motlist.528` | 村民 `nid018` 活动库 10 的动作数完成 7 → 4 → 7。尚未验证库内正在播放的片段如何采用新关键帧。 |
| `.mot.495` | 独立水车动作在播放中完成末帧 239 → 119 → 239 的覆盖与删除回退。 |
| `.rcol.20` | 通过 RequestSetCollider 的请求组绑定新资源。同一 NPC 设施碰撞文件的 42 个组全部将外圈球半径从 1.0 改为 1.25，恢复后均为 1.0。已核对运行时形状；实际接触事件、伤害判定及其他形状布局尚未验证。 |
| `.gui.430033` | 可以更新已创建视图和可唯一识别子节点的标量属性。结构不同的 GUI 在重建视图时重新解析。替换语音气泡后从实际新视图读到了不同的文字、纹理和纹理组节点数。 |
| `.pfb.17` | 通过游戏预制体工厂按路径跟踪实例，更新可识别根对象的 TimeScale、DrawSelf 和 UpdateSelf，包括后续生成的实例。玩家头顶标记另有已存在实例的匹配。实测范围见冷路径对照表。 |
| `.user.2` 固定相机 | 新增 `snow.camera.FixedCamera.FixedCameraUserData_End` 的四个插值字段。探针先持有 `roomservice_end.user` 根实例，保存后同一实例的插值时长完成 60 → 24 → 60，曲线开关完成 开 → 关 → 开。未触发客房相机过渡。 |

表中手甲 MDF 的冷贴图引用、绑定与恢复步骤见[材质验证记录](docs/material-reload.md)。[训练场与任务实测](docs/quest-equipment.md) · [荒野实现对照](docs/wilds-parity.md)

## 致谢

感谢 Stellar（AleksKavil）公开荒野热加载实现，供本项目参考文件监听、资源重载和依赖就绪后的组件刷新。感谢 praydog 及 REFramework 贡献者提供插件接口与 Lua 环境。[荒野热加载](https://github.com/AleksKavil/MHWS-Files-HotReload) · [REFramework](https://github.com/praydog/REFramework) · [第三方署名与许可](reframework/data/MHRS-Files-HotReload/THIRD_PARTY_NOTICES.md)
