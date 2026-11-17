# 更新记录

下表的版本号可下载对应的 Fluffy 安装包。1.1.0 沿用原 1.0.10 候选包中已通过实机验证的 DLL。

| 玩家版本 | 本版更新 |
| --- | --- |
| [1.1.0](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.1.0.zip) | 按当前猎人、实穿防具和资源就绪状态推进刷新。部分防具、整套及脚本重置后的装配恢复都在原猎人挂点进行。换场后重新查找实际穿戴者。缺少 TEX 或 MMTR 时等待对应文件，一次复制多个资源时按使用者分组。 |
| [1.0.9](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.9.zip) | 调整单人任务里的换装判断。开场 CG 标志在正式狩猎中仍为真时，也能刷新就绪的装备。换场期间收到的整套文件变更会留给新猎人重新核对。 |
| [1.0.8](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.8.zip) | 记录实穿材质缺少的自定义 MMTR 路径。补装模板后自动重试，其他资源可以继续刷新。 |
| [1.0.7](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.7.zip) | 放开实穿防具原位装配和单件顶点刷新的收刀、站稳条件，可以在拔刀、瞄准或移动时触发。 |
| [1.0.6](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.6.zip) | 整套防具装回原猎人的五个挂点。保留武器、副件和染色，核对新防具的材质、骨骼和活动 CHAIN 后再撤下旧件。 |
| [1.0.5](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.5.zip) | 为相同布局、只修改顶点的单件模型增加原地换绑，缩短这类修改的刷新流程。 |
| [1.0.4](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.4.zip) | 将整套外观刷新扩展到训练场和进行中的单人任务，验证当时的装备重建流程。 |
| [1.0.3](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.3.zip) | 适配玩家原装 Lua Bone System，骨骼姿态 JSON 更新后可以刷新当前装备。 |
| [1.0.2](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.2.zip) | 增加村庄整套外观的自定义骨架与穿戴物理支持。 |
| [1.0.1](https://github.com/moon135246/MHRS-Files-HotReload/releases/download/v1.1.0/MHRS-Files-HotReload-v1.0.1.zip) | 将监听器和游戏脚本打入单个 REFramework 插件 DLL。游戏启动后首次放入的松散外观也能触发刷新。 |

当前版本在村街和训练场用弓实测了自定义材质外观的安装、切换和卸载。训练场同一名猎人的天狐、梅、原版三种外观，手甲活动 CHAIN 组数分别为 16、15、2。任务 605 退任务时曾出现的加载停滞仍待定位。[实测范围](docs/wilds-parity.md)
