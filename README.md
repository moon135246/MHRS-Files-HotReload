# MHRS-Files-HotReload

《怪物猎人：崛起》资源热加载实验项目。当前原型用 REFramework Lua 读取本地猎人手甲的材质，在同一 Mesh 上验证覆盖松散 MDF 文件后的运行时变化。

## 已验证的手甲颜色热刷新

将本仓库的整个 `reframework/autorun` 目录合并到游戏的同名目录，在 `reframework/data` 下创建 `MHRS-Files-HotReload` 目录，然后加载脚本。穿上使用 `f_arm279.mdf2.23` 的手甲，在修改 MDF 前从项目目录启动监听：

```powershell
python tools/watch_arm279.py "F:\SteamLibrary\steamapps\common\MonsterHunterRise"
```

看到 `Captured 12 bindings` 后可直接保存目标 MDF。监听器合并短时间内的文件变动，游戏线程通过 `via.io.file.copy` 读取原松散路径到自己的快照，解析 MDF2.23，按材质名和参数名更新手甲。按 Ctrl+C 结束监听。手动测试可用 Script Generated UI → MHRS Files HotReload 中的 Capture 和 Read MDF 按钮。重新换装或重载脚本后，在再次修改文件前重新启动监听以采集当前手甲。

在已穿戴的同一只手甲上，`moon_RimColor` 的测试值覆盖了六个槽，延迟 8.61 秒读回仍为 (1, 0, 1, 1)。另一次仅保存文件的测试中，监听器约 0.25 秒后收到更新回执，六个槽采用新值；恢复原文件后，六槽及原 MDF 哈希均恢复。两个实验都沿用原 Mesh。当前另一个探测参数 `S_col_R` 在后续采样时回到了原有运行时值，其覆盖来源待定位。贴图、槽位增删和材质模板整体替换尚未验证。

### 资源复用与荒野实现的对照

本机 REFramework 的 Lua 绑定把请求转交给游戏的 `via.ResourceManager`。在覆盖后，原路径请求返回的原生资源地址与已穿戴 Mesh 的材质 holder 所持地址相同；NTFS 通知在显式刷新读盘时触发。可观察到的复用边界是资源管理器的返回值。崛起反射暴露的管理器方法中未找到按路径清除或重载的入口。另一次只读实验中，在逻辑路径中加入 `./` 返回了不同对象，并在主动对照读取前触发同一物理文件的打开通知；该实验未绑定新对象。

荒野版会暂时移开旧缓存条目、按原路径加载，等待 MDF 和依赖就绪后提交，再刷新正在使用它的 Mesh，并按新旧文件差异保留运行时覆盖。崛起颜色原型沿用了按材质和参数比对的思路。当前显式读盘与参数刷新保留了原资源对象，尚未完成崛起原生缓存条目的替换。[荒野加载与 Mesh 刷新实现](https://github.com/AleksKavil/MHWS-Files-HotReload/blob/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08/src/hotreload.cpp) · [REFramework 资源管理器封装](https://github.com/praydog/REFramework/blob/c4b13148/shared/sdk/ResourceManager.cpp)

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
