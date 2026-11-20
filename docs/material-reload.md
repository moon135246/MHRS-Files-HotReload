# 构建与材质验证

## 构建玩家安装包

构建单 DLL 玩家包需要 Windows x64、Python 3.12、Git 和 Visual Studio C++ x64 工具链。运行 `python tools/build_player_package.py dist/MHRS-Files-HotReload-v1.2.0.zip`。构建脚本取用固定版本的静态 CPython SDK 和 REFramework 的 Lua 源码，将监听器、脚本及资源索引一并链接进 DLL。下文的 Python 命令供源码开发与历史用例复测，手动监听和玩家 DLL 应分别运行。

首次构建会将依赖缓存到 `native/build`。本地已有对应版本时，传入 `--python-sdk <已解压的SDK目录> --reframework-source <REFramework检出目录> --zstd-source <Zstandard 1.5.7源码目录>` 可离线构建。`--verify` 在独立宿主验证单 DLL 的启动、文件变更、PAK 回退与退出，`--verify-texture <TEX文件>` 可加入真实纹理样本。使用独立进程从源码读取 PAK 需要安装 `zstandard`，`--external-watcher` 构建这一对照版本另需 PyInstaller 6。

## 整份手甲 MDF 热加载

验证环境为 Windows x64、Steam 16.0.2.0（Build 17920865）、REFramework v1.5.9.1+472-c4b13148。原生模块依赖此版游戏的内部布局与方法，并在运行时检查构建特征。

1. 这一节复现早期的开发者手动测试。在单独的开发安装中构建原生模块，部署相应的脚本与开发 DLL，启用 REFramework 的 LooseFileLoader。
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

看到 `Captured 12 bindings` 后可直接保存目标 MDF。监听器合并短时间内的文件变动，游戏线程通过 `via.io.file.copy` 读取原松散路径到自己的快照，解析 MDF2.23，按材质名和参数名更新手甲。按 Ctrl+C 结束监听。重新换装或重载脚本后，在再次修改文件前重新启动监听以采集当前手甲。

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
