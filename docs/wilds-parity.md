# 荒野功能对照与崛起冷路径实测

崛起 Steam 16.0.2.0，Build 17920865，REFramework c4b13148。荒野的支持表列出 22 种主格式，特效依赖中另外列出 UVAR 和 ABCMESH。本地崛起清单能找到其中 16 种同名主格式，另有崛起版物理链 CHAIN，以及 UVAR。以下 18 类均使用本轮新建、带随机名称的松散资源路径做过首次加载、修改和恢复。表中保留每项实际观察到的结果。[荒野参考版本](https://github.com/AleksKavil/MHWS-Files-HotReload/tree/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08)

| 崛起格式 | 游戏内观察 | 证据边界 |
| --- | --- | --- |
| MDF2.23 | 独立 Mesh 使用新路径 MDF，保存时新增、移除指定贴图引用；另在当前角色的原路径手甲执行冷贴图测试 | 手甲测试比对同一 Mesh 的六槽全部贴图绑定和原件 SHA-256 |
| TEX.28 | 新路径首次被手甲的 MDF 引用，文件打开落在保存和绑定回执之间。独立 Mesh 对新路径 TEX 的两次单独保存都重新绑定 | 手甲本轮为绑定读回，早期洋红色测试另有画面观察 |
| MMTR.220427553 | 随机路径模板被随机路径 MDF 引用。替换和恢复模板均引发同一 Mesh 重新绑定其 MDF | 只索引能在松散目录中读取的 MDF，未逐像素比较着色结果 |
| MESH.2109148288 | 新路径的两份模型在同一 Mesh 组件中替换并恢复，均就绪 | 独立组件的这次试验记录绑定；手甲顶点位移另有场景测试 |
| RTEX.5 | 同一 GUI 的 RenderTarget 三次读回均为新逻辑路径，保存后两次换为新资源对象 | 未读回渲染目标像素。只放置带额外 `.stm` 的 RTEX 文件时未通过 |
| EFX.2818730 | 新路径 EFX 在同一播放器做了两次重绑；正在播放的玩家特效还实际加载了新路径 UVS | 后者在恢复后重新运行，保持 4 个任务和 4 个发射器 |
| UVS.7 | 玩家 EFX 首次打开冷路径 UVS，仅保存 UVS 即触发 EFX 重绑。另一次令 UVS 引用全新的 TEX，观测到该 TEX 首次打开，随后只保存 TEX 就能依次重载 UVS 和正在播放的 EFX。改回后播放器恢复 4 个任务 | 已验证 TEX → UVS → EFX 两级松散依赖。引擎单独生成、没有 EffectPlayer 可追踪的特效实例仍待验证 |
| UVAR.3 | 同一 Motion 的变量组名完成 `em001_00_mot → em002_00_mot → em001_00_mot` | 读回实际变量组 |
| FBXSKEL.4 | 同一 CustomSkeleton 的 0 号骨骼局部 X 完成 0 → 0.125 → 0 | 读回骨骼变换 |
| CHAIN.48 | 同一组件的物理资源组数完成 4 → 3 → 4 | 对应荒野 CHAIN2。两个版本的文件布局不同 |
| JCNS.21 | 独立约束层的输出目标数完成 4 → 3 → 4 | 另有已穿戴腰甲与活动 NPC 的原路径覆盖测试 |
| MOTBANK.3 | 组件活动库编号完成 `[0,10] → [0,12] → [0,10]` | 读回实际动作库 |
| MOTLIST.528 | 活动库 10 的动作数完成 7 → 4 → 7 | 不涵盖正在播放的片段逐帧采用新关键帧 |
| MOT.495 | 找到 `via.motion.TreeLayer.Resource`，在同一层上两次更换独立 MOT 持有器并恢复原始文件内容 | 临时层的帧数为 0。用狩猎设施 PFB 做播放对照时未找到活动引用，播放效果仍待验证 |
| RCOL.20 | 随机路径的原生 ItemTake 预制体首次加载随机 RCOL，同一请求组的外圈球半径完成 2.3 → 2.625 → 2.3，内圈保持 0.1 | 临时实例成功销毁。较早两次试验出现游戏退出，其中一次发生在切回旧持有器时。当前测试使用独立预制体。过滤掩码、绑定关节与接触事件未逐项验证 |
| GUI.430033 | 随机路径 View 的 BaseFps 完成 60 → 41 → 60。在村内另以原路径新覆盖文件令 49 个对话气泡的文字子节点隐藏并恢复，帧率完成 60 → 37 → 60 | 同布局、唯一类名和节点名的标量更新。新增、删除节点和结构变更仍有缺口 |
| PFB.17 | 随机路径原生 PFB 的已生成实例 TimeScale 完成 −1 → 0.5625 → −1；两次保存之间生成的另一个实例初值为 0.5625，恢复时两个实例都变回 −1 | 按工厂调用记录来源路径，支持可识别根对象的三个标量。插件启动前的普通实例、子对象和任意组件字段均不在此范围 |
| USER.2 | 三条新路径分别测试 StageDissolveData、CameraUserData_OptionMenuCameraOffset、CameraUserData_UntiGroinOffsetParam。三次都在同一对象上改动并恢复浮点字段 | 通用模式依赖相符的 RSZ 类型 ID、CRC 和字段反射，仅支持单根固定标量布局。头盔和固定镜头另有专用处理 |

### 尚缺的格式和行为

本地 `MHR_STM_Release.list` 中没有找到 EFCSV、HTEX、CLSP、GPUC、SFUR、ABCMESH 的同名资源。清单包括带平台后缀的条目。没有崛起样本可用于这六项的原生消费者和冷加载验证。即使同为 RE Engine，也不能把荒野文件直接作为通过样本。

场景 Mesh 的材质槽开关可以保留，任意运行时材质参数的差异合并仍未实现。GUI/PFB/USER 当前都有明确的字段和布局边界。RTEX 的像素内容、动作播放中的关键帧、没有松散引用文件的特效依赖、碰撞所有字段也没有全量验证。

### 重现冷加载

1. 游戏内启用 LooseFileLoader。测试启动后才新增的松散覆盖时，在 `LooseFileLoader → Debug` 暂时关闭 `Enable file cache`。村内玩家 EFX 实测在开关启用时返回过绑定回执，却没有打开新的 UVS；关闭后以另一条全新路径重新测得首次打开。
2. 启动 `tools/watch_outfit.py`，用 `python -u` 运行并将标准输出重定向到文件。GUI、PFB 和 USER 可用 `--baseline-root "<同游戏版本的原版 natives/stm>"` 在第一次保存时计算差异。通用单根 USER 另加 `--rsz-schema "<rszmhrise.json>"`。
3. 可在 REFramework 的 ScriptRunner 中运行 `tools/cold_component_probe.lua`，再执行下面的命令。原件与改件均由测试者提供。工具生成唯一逻辑路径，验证同一组件的首次绑定、替换与恢复，输出 JSON 并销毁临时实例。该命令覆盖六种直接绑定的格式；手甲的独立文件打开观测使用 README 中的 `test_cold_arm279.py`。

```powershell
python tools/test_cold_component.py "<游戏目录>" "<监听日志>" chain "<原件.chain.48>" "<改件.chain.48>"
```

仓库保留了[冷加载实机读数](cold-results.json)。本机完整记录在 `local-tests/parity`，材质联测为 `2067cdfd`，玩家 UVS 为 `8be50ad0`，两级特效依赖为 `93dc5c52`，RCOL 为 `435b6c63`，PFB 为 `6aeef0bf`。
