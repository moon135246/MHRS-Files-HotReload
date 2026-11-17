# 怪物猎人：崛起／曙光 · 外观热加载

在游戏运行时安装、修改或卸载外观 MOD，当前猎人的防具、材质和贴图会随文件更新。村庄、训练场和单人任务都可以使用，持武器、瞄准或移动时也能刷新防具。

## 用 根目录 安装

退出游戏，解压 MHRS-Files-HotReload-v1.0.0.zip，把包内的 reframework 合并到游戏根目录（MonsterHunterRise.exe 所在目录）

## 用 Fluffy 安装

1. 先安装崛起版 REFramework，启用 **LooseFileLoader**。从旧版升级时，退出游戏并停止之前手动运行的 Python 监听器。
2. 在下方 Assets 下载 **MHRS-Files-HotReload-v1.0.0.zip**。在 Fluffy Mod Manager 中选择 **Monster Hunter Rise**，拖入整个 ZIP，或将 ZIP 放入 Fluffy 的 `Games/MHRISE/Mods` 并刷新列表。启用 **MHRS-Files-HotReload**。
3. 启动游戏，插件会在后台自动开始监听。要在游戏运行中新增或删除文件，请在 **LooseFileLoader → Debug** 中关闭 **Enable file cache**。实测 REFramework 版本在游戏重启后会重新勾选此项。
4. 编辑或删除 `natives/stm` 下的资源。运行记录位于游戏目录的 `reframework/data/MHRS-Files-HotReload/watcher.log`。日志显示 `Next use` 时，换装或重新进入对应场景可让新对象读取当前资源。退出游戏后可在 Fluffy 中停用插件。

[构建与材质验证](docs/material-reload.md) · [18 类资源的替换与回退](docs/reentry-18.md) · [骨架与穿戴物理](docs/worn-skeletons.md)

## 更新日志

- **1.1.0** 单件与整套防具按当前挂点刷新，贴图、模板就绪后分组更新。
- **1.0.9** 修复开场演出结束后仍无法换装的问题，换场后重新匹配装备。
- **1.0.8** 记录缺失的 MMTR 路径，补装模板后继续换装。

- **1.0.7** 拔刀、瞄准和移动时都可刷新防具。
- **1.0.6** 保留武器、副件和染色，在原挂点更新五件防具。
- **1.0.5** 只修改顶点且布局相同时，直接更新当前模型。
- **1.0.4** 整套外观可以在训练场和进行中的单人任务里刷新。
- **1.0.3** 适配Lua Bone System，保存姿态 JSON 即可更新装备。
- **1.0.2** 在村庄换装时一并更新骨架和防具物理。
- **1.0.1** 改为单 DLL 安装，游戏启动后首次添加外观即可刷新。
- **1.0.0** 支持 18 类游戏资源的热加载。

## 致谢

感谢 Stellar（AleksKavil）公开荒野热加载实现，供本项目参考文件监听、资源重载和依赖就绪后的组件刷新。感谢 praydog 及 REFramework 贡献者提供插件接口与 Lua 环境。[荒野热加载](https://github.com/AleksKavil/MHWS-Files-HotReload) · [REFramework](https://github.com/praydog/REFramework) · [第三方署名与许可](reframework/data/MHRS-Files-HotReload/THIRD_PARTY_NOTICES.md)
