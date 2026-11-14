# MHRS-Files-HotReload

《怪物猎人：崛起》资源热加载实验项目。当前原型用 REFramework Lua 读取本地猎人手甲的材质，在同一 Mesh 上验证覆盖松散 MDF 文件后的运行时变化。

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

## 复测同路径覆盖

1. 安装适用于崛起的 REFramework，启用 LooseFileLoader。将项目的 `reframework/autorun/MHRS_Files_HotReload.lua` 复制到游戏的同名目录，并在 `reframework/data` 下创建 `MHRS-Files-HotReload` 目录。启动游戏，或在 REFramework 的 ScriptRunner 面板点击 Reset scripts。
2. 在村内穿戴使用目标材质的手甲，保持装备和场景不变。此测试针对包含 `S_col_R`、`moon_RimColor` 两个四分量参数的自定义 `f_arm279.mdf2.23`。测试期间暂停对该源文件的其他编辑。
3. 在项目目录运行 `python tools/test_arm279.py "F:\SteamLibrary\steamapps\common\MonsterHunterRise" --observe-opens`，按实际安装位置替换路径。文件观察适用于本地 NTFS。工具会备份原件，生成测试颜色，原子替换目标文件，然后分别记录覆盖后、请求原资源后和恢复文件后的参数。观察结束时，工具主动读取目标文件，以校验通知及测试内容。
4. 原件备份及逐槽 JSON 记录位于 `local-tests/<本次测试编号>/`。如测试进程被强制中断，可从该目录把 MDF 复制回 `natives/stm/player/mod/f/pl279/`。

## 致谢

- 感谢 [AleksKavil / MHWS-Files-HotReload](https://github.com/AleksKavil/MHWS-Files-HotReload)（Stellar）。荒野版对松散资源变更、引擎缓存与当前场景引用的处理，为崛起版的实验设计提供了参考。当前 Lua 原型和测试工具独立编写。[参考版本 e3ef3e0](https://github.com/AleksKavil/MHWS-Files-HotReload/tree/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08)
- 感谢 [praydog / REFramework](https://github.com/praydog/REFramework) 提供游戏内脚本运行环境、资源 API 和对象反射接口。
