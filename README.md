# MHRS-Files-HotReload

《怪物猎人：崛起》资源热加载实验项目。保存松散文件后，插件在游戏线程更新相应的资源或实例属性。支持服装、物理、特效、动作列表，以及下表列出的 GUI、预制体和 USER 属性。已在 Steam 16.0.2.0、Build 17920865、REFramework c4b13148 上验证。

## 安装与实测范围

本轮逐项对照荒野的 22 种主格式，并用随机新路径验证了 18 类崛起资源。格式对应关系、具体读数、未覆盖的行为和复测命令见[荒野功能对照与崛起冷路径实测](docs/wilds-parity.md)。

将项目的 `reframework` 目录合并到游戏目录，启用 REFramework 的 LooseFileLoader。已运行的游戏安装新版原生模块时，可先在 ScriptRunner 中重载脚本释放旧 DLL，再复制新版。使用 Windows Python 运行一个服装监听器。它同时处理原有的手甲 MDF。先退出单文件监听器，再执行：

```powershell
python tools/watch_outfit.py "F:\SteamLibrary\steamapps\common\MonsterHunterRise"
```

监听器查找 `natives/stm` 下的松散文件。物理、动作、渲染、特效和碰撞按资源路径匹配当前场景中正在更新的组件。GUI 匹配已就绪的视图，头盔 USER 匹配本地猎人。每次保存后，终端打印绑定、字段更新或跳过原因。

| 资源 | 村内实机测试 |
| --- | --- |
| `.chain.48` | 手甲的活动组数和资源组数均完成 15 → 14 → 15。保存 `npc018.chain.48` 后，共用它的两个活动 NPC 的物理组数同步完成 4 → 3 → 4。 |
| `.jcns.21` | 保存 `f_wst279_drv.jcns.21` 后，当前腰甲的关节约束层输出目标数完成 4 → 11 → 4。四个使用 `npc016_00_body_drv.jcns.21` 的 NPC 同步完成 12 → 11 → 12，一个使用艾露猫公共约束 `otomo000_body_drv.jcns.21` 的场景对象完成 8 → 7 → 8。 |
| `.motbank.3` | 保存 `npc018_00_bank.motbank.3` 后，村民动作组件中的活动 BankID 列表完成 `[0,10] → [0,11] → [0,10]`。已验证主动作库绑定和活动编号，尚未验证动作片段播放效果。 |
| `.mesh.2109148288` | 修改手甲顶点后，同一 Mesh 组件换用新资源，画面出现位移。恢复后模型再次就绪。 |
| `.tex.28` | 单独覆盖 `moon_5.tex.28`，手甲的两个使用槽同步变为洋红色，恢复后两槽再次绑定原路径的新资源。 |
| `.mmtr.220427553` | 将 `Moon_Mask_Dissolve` 换为另一份已有的崛起版模板，约 3.2 秒完成模板及手甲、腰甲两份 MDF 的重载。恢复原模板后再次核对两个组件。依赖查找限于磁盘上有松散 MDF 的已穿戴部件。 |
| `.user.2` | 按文件差异写入头盔的 `PlayerUserDataPartsHelm` 实例。实测 `FullFace`、`HairChainStop` 和 `HairShapeData[0]` 可修改并恢复。验证的是实例字段读数。外观或模拟下次何时使用各字段，取决于游戏的消费时机。支持现有头发与脸部记录、相同数组长度及空的 `_ChainChangeList`。 |
| `.mdf2.23` | 原路径整份材质替换。手甲的冷贴图引用与恢复结果见下节。 |
| `.efx.2818730` | 已启动的 EffectPlayer 跨帧绑定新资源并重新播放。当前角色 `effect_player00` 的任务数和发射器数都完成 4 → 2 → 4。另测得只保存被引用的冷路径 UVS 即可触发正在播放的玩家 EFX 重载。 |
| `.motlist.528` | 村民 `nid018` 活动库 10 的动作数完成 7 → 4 → 7。更新活动库持有的列表。已在播放的片段逐帧更新、单独保存外部 `.mot.495` 尚未验证。 |
| `.rcol.20` | 通过 RequestSetCollider 的请求组绑定新资源。同一 NPC 设施碰撞文件的 42 个组全部将外圈球半径从 1.0 改为 1.25，恢复后均为 1.0。已核对运行时形状；实际接触事件、伤害判定及其他形状布局尚未验证。 |
| `.gui.430033` | 更新已创建视图和可唯一识别的子节点的标量属性。村内 49 个 `SpeechBalloon.gui` 文字节点的 Visible 与根视图 BaseFps 完成 可见/60 → 隐藏/37 → 可见/60。结构编辑会报告跳过。 |
| `.pfb.17` | 通过游戏预制体工厂按路径跟踪实例，更新可识别根对象的 TimeScale、DrawSelf 和 UpdateSelf，包括后续生成的实例。玩家头顶标记另有已存在实例的匹配。实测范围见冷路径对照表。 |
| `.user.2` 固定相机 | 新增 `snow.camera.FixedCamera.FixedCameraUserData_End` 的四个插值字段。探针先持有 `roomservice_end.user` 根实例，保存后同一实例的插值时长完成 60 → 24 → 60，曲线开关完成 开 → 关 → 开。未触发客房相机过渡。 |

GUI、PFB 和 USER 采用文件差异更新。默认以启动时的松散文件或运行中首次看到的文件作为基线。另可传入同一游戏补丁版本的原始资源目录 `--baseline-root "<原版 natives/stm>"`，让首次保存就能计算差异。指定 `--rsz-schema "<rszmhrise.json>"` 可启用单根标量 USER 的类型检查与实时写入。

如果游戏启动后才第一次把某个原版资源放到 `natives/stm`，LooseFileLoader 可能已缓存该路径没有松散文件的结果。实测腰甲在这种情况下仍读到原版 4 个约束输出。在 REFramework 的 **LooseFileLoader → Debug** 取消勾选 **Enable file cache** 后再次保存，腰甲立即读到松散文件的 11 个输出。监听器在绑定单组 JCNS 前会对照磁盘和新资源的输出数量，数量不符时回滚，保留原约束层。这项检查只比较数量。

材质刷新会尝试按名称恢复材质槽的启用开关。其他插件临时写入的材质参数仍可能需要重新应用。通用预制体结构重建、任意 USER 类型及 GUI 子控件树的刷新仍待实现。

## 整份手甲 MDF 热加载

验证环境为 Windows x64、Steam 16.0.2.0（Build 17920865）、REFramework v1.5.9.1+472-c4b13148。原生模块依赖此版游戏的内部布局与方法，并在运行时检查构建特征。

1. 安装 REFramework，启用 LooseFileLoader。将项目中的 `reframework` 目录合并到游戏目录。此目录同时包含脚本和配套的 `data/MHRS-Files-HotReload/arm_material.dll`。已运行的游戏可在 ScriptRunner 中点 Reset scripts。
2. 穿上使用目标 MDF 的手甲，在项目目录运行以下命令。监听器运行期间直接保存 `natives/stm/player/mod/f/pl279/f_arm279.mdf2.23`，按 Ctrl+C 结束监听。

```powershell
python tools/watch_arm279.py "F:\SteamLibrary\steamapps\common\MonsterHunterRise" --native
```

原生流程借鉴荒野版对旧资源生命周期、依赖就绪和当前 Mesh 绑定的处理。崛起的路径缓存使用有序树。模块在管理器的临界区内将旧对象暂存到另一个键，调用游戏自身的资源创建函数重新请求原路径。新 MDF、材质模板和贴图准备就绪后，脚本绑定新 holder，再释放事务引用。旧对象随现有使用者的引用正常释放。失败或依赖等待超时会尝试恢复原缓存条目。

实测只更改 `Meira_5_outer_Arm / BaseDielectricMap` 的贴图引用。手动和保存触发各完成一次 `moon_5.tex → moon_6.tex → moon_5.tex`。每次使用同一 Mesh 和原逻辑路径，MDF 对象地址随重载更新。对六个材质槽的 56 个贴图绑定逐项比较，只有目标引用变化。自动监听实测两次保存到绑定回执约 0.96 秒、0.84 秒，测试结束原文件 SHA-256 与基线一致。

首次引用新贴图时，只等待依赖就绪会导致超时。实测新纹理进入资源缓存后已完成第一阶段加载，第二阶段仍处于待处理状态。现行模块在游戏线程上调用崛起自身的资源初始化函数，确认纹理就绪后才绑定整份 MDF。在村内给当前手甲引用新路径的洋红色 BC7 sRGB 贴图，保存约 0.45 秒后观测到贴图文件打开，1.00 秒收到绑定回执。角色手甲的两圈白色毛边之间从深色变为洋红色。改回原件后约 0.86 秒收到回执，画面恢复深色，六槽的全部绑定及原文件哈希均恢复。以上结果针对该手甲、同一材质模板和槽布局。

编译可运行 `native/build.cmd`，需要 Visual Studio C++ x64 工具链。复测贴图前先退出监听器，再运行 `python tools/test_native_arm279.py "F:\SteamLibrary\steamapps\common\MonsterHunterRise"`。报告和备份保存在 `local-tests/native-<编号>/`。如果外部测试进程被强制终止，原件可从该目录恢复。

复测首次引用的新贴图时，保持原生监听器运行，并将其标准输出重定向到日志文件。另开终端运行 `python tools/test_cold_arm279.py "<游戏目录>" "<监听日志路径>"`。该测试需要上述自定义手甲和原贴图 `moon_5.tex.28`，会生成唯一命名的测试纹理，验证保存和恢复两次绑定，并在恢复后清理纹理。记录和原件保存在 `local-tests/cold-<编号>/`。

## 早期颜色刷新模式

将本仓库的整个 `reframework/autorun` 目录合并到游戏的同名目录，在 `reframework/data` 下创建 `MHRS-Files-HotReload` 目录，然后加载脚本。穿上使用 `f_arm279.mdf2.23` 的手甲，在修改 MDF 前从项目目录启动监听：

```powershell
python tools/watch_arm279.py "F:\SteamLibrary\steamapps\common\MonsterHunterRise"
```

看到 `Captured 12 bindings` 后可直接保存目标 MDF。监听器合并短时间内的文件变动，游戏线程通过 `via.io.file.copy` 读取原松散路径到自己的快照，解析 MDF2.23，按材质名和参数名更新手甲。按 Ctrl+C 结束监听。手动测试可用 Script Generated UI → MHRS Files HotReload 中的 Capture 和 Read MDF 按钮。重新换装或重载脚本后，在再次修改文件前重新启动监听以采集当前手甲。

在已穿戴的同一只手甲上，`moon_RimColor` 的测试值覆盖了六个槽，延迟 8.61 秒读回仍为 (1, 0, 1, 1)。另一次仅保存文件的测试中，监听器约 0.25 秒后收到更新回执，六个槽采用新值；恢复原文件后，六槽及原 MDF 哈希均恢复。两个实验都沿用原 Mesh。当前另一个探测参数 `S_col_R` 在后续采样时回到了原有运行时值，其覆盖来源待定位。该颜色模式仅处理上述参数。

### 资源复用与荒野实现的对照

本机 REFramework 的 Lua 绑定把请求转交给游戏的 `via.ResourceManager`。在覆盖后，原路径请求返回的原生资源地址与已穿戴 Mesh 的材质 holder 所持地址相同；NTFS 通知在显式刷新读盘时触发。可观察到的复用边界是资源管理器的返回值。崛起反射暴露的管理器方法中未找到按路径清除或重载的入口。另一次只读实验中，在逻辑路径中加入 `./` 返回了不同对象，并在主动对照读取前触发同一物理文件的打开通知；该实验未绑定新对象。

荒野版会暂时移开旧缓存条目、按原路径加载，等待 MDF 和依赖就绪后提交，再刷新正在使用它的 Mesh，并按新旧文件差异保留运行时覆盖。崛起颜色原型沿用了按材质和参数比对的思路。此处的早期颜色实验保留了原资源对象；原生模式的实测见上节。[荒野加载与 Mesh 刷新实现](https://github.com/AleksKavil/MHWS-Files-HotReload/blob/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08/src/hotreload.cpp) · [REFramework 资源管理器封装](https://github.com/praydog/REFramework/blob/c4b13148/shared/sdk/ResourceManager.cpp)

## 首次实机结果

2026-11-14，Steam Build 17920865，游戏 16.0.2.0，REFramework v1.5.9.1+472-c4b13148。角色已穿戴使用 `player/mod/f/pl279/f_arm279.mdf2` 的手甲。测试期间保持装备和场景固定。

| 操作 | 六个已启用材质槽的 `moon_RimColor` 读数（约值） |
| --- | --- |
| 覆盖前 | 全部为 (0.70, 0.68, 0.74, 0.08) |
| 原路径覆盖，等待 1.5 秒后请求采样 | 全部保留旧值；测试文件中写入的是 (1, 0, 1, 1) |
| 用 `sdk.create_resource` 请求原路径，创建 holder 并调用 `set_Material`，再次采样 | 同一 Mesh 的六个槽仍保留旧值 |

本次采样未观察到当前手甲立即采用新值。实验不能单独确定资源缓存、加载时序或其他插件分别起了什么作用。`S_col_R` 的运行时初值和文件初值已有差异，因此以上表格使用与原文件一致的 `moon_RimColor` 判断。

另一次异路径对照在绑定请求返回后游戏退出，未取得绑定后的样本。该分支已移出原型。测试工具已恢复原 MDF，恢复前后的原件 SHA-256 为 `23b026bb53abff3983a2a2142334d16a9d6f574026da35d3449d01577dec1e20`。

## 原路径请求的文件访问复测

在相同装备下原子替换目标 MDF，随后在新文件上申请 NTFS batch oplock。等待观察就绪后通过游戏内探针请求原资源路径并重新绑定。请求返回后继续观察 8.61 秒，六个槽在早、晚两次采样中都保持旧值。整个观察窗口内没有触发打开通知。随后测试工具主动读取同一文件，立即触发首次通知，读到的内容与修改版 SHA-256 完全一致。

在这次测试条件下，没有观察到引擎重新打开覆盖后的松散 MDF 读取新内容。此方法观察单个文件，不能定位具体缓存层。系统级 ETW 会话未获得管理员权限，本次使用文件级观测。原文件已按 SHA-256 核对恢复；旧版探针重新绑定保存的 holder 后，游戏在最后一次采样前退出。现行探针只请求资源并读取当前材质，已移除两个设置材质的调用。

移除材质绑定后，在村内对同一手甲单独执行 `sdk.create_resource`。调用返回了资源对象，之后 8.31 秒内未观察到覆盖后的 MDF 被重新打开。首次打开通知出现在测试工具主动读取文件时，读取内容与测试版哈希一致。两次采样中六个槽均保留初值。恢复后再次核对，原文件哈希、六个槽的名称、启用状态、`S_col_R` 和 `moon_RimColor` 均与覆盖前一致，游戏持续运行。

## 复测同路径覆盖

1. 按上面的安装步骤部署入口和 MDF 解析模块，启用 LooseFileLoader。启动游戏，或在 REFramework 的 ScriptRunner 面板点击 Reset scripts。单独运行验证程序前先退出监听器。
2. 在村内穿戴使用目标材质的手甲，保持装备和场景不变。此测试针对包含 `S_col_R`、`moon_RimColor` 两个四分量参数的自定义 `f_arm279.mdf2.23`。测试期间暂停对该源文件的其他编辑。
3. 在项目目录运行 `python tools/test_arm279.py "F:\SteamLibrary\steamapps\common\MonsterHunterRise" --observe-opens`，按实际安装位置替换路径。文件观察适用于本地 NTFS。工具会备份原件，生成测试颜色，原子替换目标文件，然后分别记录覆盖后、请求原资源后和恢复文件后的参数。观察结束时，工具主动读取目标文件，以校验通知及测试内容。
4. 原件备份及逐槽 JSON 记录位于 `local-tests/<本次测试编号>/`。如测试进程被强制中断，可从该目录把 MDF 复制回 `natives/stm/player/mod/f/pl279/`。
5. 在上述验证命令后追加 `--refresh` 可测试显式读取原 MDF 并刷新手甲颜色。

## 致谢

- 感谢 [AleksKavil / MHWS-Files-HotReload](https://github.com/AleksKavil/MHWS-Files-HotReload)（Stellar）。荒野版对松散资源变更、引擎缓存与当前场景引用的处理，为崛起版的实验设计提供了参考。当前 Lua 原型和测试工具独立编写。[参考版本 e3ef3e0](https://github.com/AleksKavil/MHWS-Files-HotReload/tree/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08)
- 感谢 [praydog / REFramework](https://github.com/praydog/REFramework) 提供游戏内脚本运行环境、资源 API 和对象反射接口。
