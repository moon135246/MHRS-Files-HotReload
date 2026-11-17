# 任务中的穿戴外观

本文的 `local-tests/` 链接指向开发机保存的原始回执。各项实测读数已列在正文中。

## 1.0.6 训练场的十四类武器

女 279 猎人在装备箱中换好武器、回到场上后，依次安装梅、切换天狐、关闭外观。FirstNatives 独立加载松散文件时关闭 REFramework 的 LooseFileLoader，玩家原装 Lua Bone System 则配合开启的 LooseFileLoader 单独测试。两种配置各覆盖十四类武器，各通过 42 次切换，合计 84 次。每类武器的四份场上快照均保留猎人根对象、玩家对象、PlayerData、材质控制器，以及原有的主武器和该武器配有的副件。五件防具挂在原猎人上，逐件核对材质、关节和活动 CHAIN。两轮结束后都穿回存档第 215 格的弓「赤绝飞翼老人星」，读回弓和箭囊，同时区分了第 56 格的同名副本。[FirstNatives 逐项验收](../local-tests/mount-live/i-first-14/summary.json) · [原装 Lua 逐项验收](../local-tests/mount-live/i-lua-14/summary.json) · [FirstNatives 最终装备](../local-tests/mount-live/i-first-14/final-215-inventory.json) · [原装 Lua 最终装备](../local-tests/mount-live/i-lua-14/final-215-inventory.json)

每类武器记录原版、梅、天狐、卸载后原版四种状态，另在每轮开始和结束时各读一次原弓。两轮共 116 份染色快照，五件防具两路启用色共 1,160 个组件读数，实际材质共 6,656 个着色器通道读数，全部与当前猎人的存档配色相符。穿梅或天狐时游戏隐藏原脸和头发，卸载后在原对象上恢复绘制。[FirstNatives 太刀切天狐的染色](../local-tests/mount-live/i-first-14/02-slot5-fox-dye.json) · [原装 Lua 最终原弓的部件和脸发](../local-tests/mount-live/i-lua-14/final-215.json)

## 1.0.6 废神社单人探索 101

FirstNatives 模式下，猎人持第 5 格太刀「凶刀【催花雨】」，在废神社主营地从原版安装梅，再切天狐、卸载。三步使用同一个任务实例，猎人、材质控制器、太刀 `LS_Swd129` 和刀鞘 `LS_Saya129` 的对象地址一致。每次都核对五个已登记的部件及四处正在模拟的 CHAIN。卸载后原脸与头发恢复绘制，红披风从主营地一直显示到结算。正常回村后，在村庄猎人上再装梅、卸载，同样恢复了存档配色。[原版猎人](../local-tests/mount-live/i-first-101-root.json) · [梅](../local-tests/mount-live/i-first-q101-1-mei.json) · [天狐](../local-tests/mount-live/i-first-q101-2-fox.json) · [卸载](../local-tests/mount-live/i-first-q101-3-none.json) · [结算特写](../local-tests/mount-live/i-first-101-closeup.jpg) · [回村卸载后的染色](../local-tests/mount-live/i-first-postquest-village-2-none-dye.json)

## 1.0.6 水没林单人狩猎 308

以原装 Lua Bone System 和 REFramework LooseFileLoader 进入村三星「被毒雾侵蚀的水没林」，目标为毒狗龙王。角色收着第 31 格操虫棍。安装梅、覆盖天狐和卸载的全过程中，任务 308 的活动实例、猎人根对象、玩家、PlayerData 和材质控制器一致，操虫棍 `I_Gla084` 与猎虫 `IG_Ins001` 也始终是原来的对象。[入场与任务状态](../local-tests/mount-live/i-lua-308-enter.json) · [原版猎人和主副件](../local-tests/mount-live/i-lua-308-root.json)

| 场上外观 | 最后一个原生文件就位至可见资源就绪 | 身、手、腰、头活动 CHAIN 组 | 与存档配色吻合的着色器通道 | 实机记录 |
| --- | ---: | --- | ---: | --- |
| 安装梅 | 2.72 秒 | 1、15、8、23 | 120 | [挂点](../local-tests/mount-live/i-lua-q308-1-mei.json) · [计时](../local-tests/direct-live/i-lua-q308-1-mei-timing.json) · [画面](../local-tests/mount-live/i-lua-308-mei.jpg) |
| 切换天狐 | 3.81 秒 | 16、16、9、21 | 92 | [挂点](../local-tests/mount-live/i-lua-q308-2-fox.json) · [计时](../local-tests/direct-live/i-lua-q308-2-fox-timing.json) · [画面](../local-tests/mount-live/i-lua-308-fox.jpg) |
| 关闭外观 | 3.00 秒 | 1、2、2、1 | 12 | [挂点](../local-tests/mount-live/i-lua-q308-3-none.json) · [计时](../local-tests/direct-live/i-lua-q308-3-none-timing.json) · [画面](../local-tests/mount-live/i-lua-308-stock.jpg) |

三次共采到 1,754 帧，猎人根对象隐藏 0 帧。五件防具每次都登记在原控制器，腿甲始终没有 CHAIN。Lua 前置把头骨当前局部 Y 从 0.12800001 调为 0.05474756，两套外观读数相同，卸载后回到 0.12800001。每一步都另读了五个部件的两路存档染色及实际材质通道。卸载后原脸和头发在各自对象上恢复绘制，任务结算近景中仍可见原脸、白色发髻和红披风。[梅的染色](../local-tests/mount-live/i-lua-q308-1-mei-dye.json) · [天狐的染色](../local-tests/mount-live/i-lua-q308-2-fox-dye.json) · [卸载后的染色](../local-tests/mount-live/i-lua-q308-3-none-dye.json) · [卸载后的任务结算](../local-tests/mount-live/i-lua-308-result-stock.jpg)

## 雪鬼兽任务里复现的旧版问题

在 Steam 16.0.2.0 的单人雪鬼兽任务 10708 中，本地猎人为弓，身穿女 279。启动后安装梅，1.0.3 已经刷新了 Lua Bone System 的头骨局部位置，头部 Y 从 0.12800001 变为 0.05474756，但猎人身上手甲的活动 CHAIN 仍是原版的 2 组。仅凭文件变更日志或头骨位置会误判整套换装成功。[原版](../local-tests/quest-live/before.json) · [装梅后](../local-tests/quest-live/old-dll-confirmed.json)

在营地帐篷中正常将弓换成太刀，游戏经由 `EquipDataManager.reloadPlayerModel` 请求玩家加载，并装配五件外观。离开帐篷后，五件材质槽数为头 21、身 1、手 6、腰 31、腿 1。头、身、手、腰的活动物理组数分别为 23、1、15、8。这个操作验证了游戏的换装流程，也为原地刷新提供了对照。[游戏调用记录](../local-tests/quest-live/tent-trace.json) · [穿梅的太刀猎人](../local-tests/quest-live/tent-longsword.json)

## 主控猎人和队友

已安装的差分管理器在 `ArmorVariantManager_Core/Games/Rise/Actors.lua` 中先从 PlayerManager 找主控，再遍历 PlayerList，使用玩家索引和有效的 GameObject 建立本机显示列表。热加载以同样的主控识别方式为基础。主控采用 `PlayerManager.findMasterPlayer()`、本地索引和玩家对象进行确认。在任务内使用 QuestManager 的任务编号、地图、活动任务对象和任务阶段跟踪当前场景。1.0.6 的整套变更等待本地猎人收刀、站稳、可操作（[1.0.7 已解除原挂点的姿态限制](wilds-parity.md#107持武器时的刷新)），由游戏把防具部件装配到原猎人，再核对装备索引、材质槽和实际运行的物理组。等待期间多次覆盖同一外观时取最后落盘的资源。

队友是本机上的独立显示对象。插件按当前场景分别读取据点或任务成员表，并和 PlayerList 的索引、成员标识及显示对象交叉核对。离场、索引复用和盟友 NPC 均单独处理。变更只作用于本机画面。

队友的单 MDF、保持原版布局的顶点位置修改、单 CHAIN，以及关节布局相容的 FirstNatives 影骨，使用各自现有的显示组件验证。Lua Bone System 按每名猎人实际穿的部件选择 JSON，插件按该猎人的影骨提供基础姿态；玩家前置文件保留原件。队友已经穿在身上的整套梅 ↔ 天狐会等待游戏重新生成该队友的显示模型。两人同款、异款、离场和重用索引的路径均有模拟用例。单客户端实机目前只看到了主控，尚未完成两名真人同时在场的验收。

名册在入场、离场和换区时可能暂时读不全。1.0.4 最终版直接从已确认的本地主控取得五件部件；发现队友或来源不明的玩家装备时会独立核对其归属。跨帧装配、等待组件重新启用、取消和回滚时会再检查一次，避免旧部件被转交后仍写入。与玩家无关的场景资源继续按原路径处理。这些异常场景有离线回归覆盖。[装备归属用例](../tools/test_peer_equipment.lua) · [CHAIN 归属用例](../tools/test_peer_physics.lua)

### 正常联机时的只读记录

照常进行狩猎即可采样。手动在 REFramework 的 ScriptRunner 中运行工作区的 [observe_multiplayer.lua](../tools/observe_multiplayer.lua)，然后收起面板。脚本读取本机显示的场景和猎人，在角色或装备状态变化时记录，稳定时每分钟记一条。记录文件位于游戏目录的 `reframework/data/MHRS-Files-HotReload/online-observations.json`，单次会话保留最近 48 条。该脚本是工作区的可选工具，玩家 ZIP 只有热加载 DLL。

打开 Script Generated UI 下的 **MHRS read-only multiplayer observations** 可暂停、手动采样或勾选头骨位置。记录包括本机角色分类和槽号、任务号、地图、五个穿戴部件的材质槽、资源与活动 CHAIN 组数。玩家名、联网账号及成员标识不写入文件。路人同场时由玩家正常操作，此记录只观测本机显示。

单人修炼场的只读冒烟测试中，工具实际识别主控槽号 0，读回原版头、身、手、腰 CHAIN 组数 1、1、2、2，勾选后记录到头骨基础与当前 Y 均为 0.128。此样本只有一名猎人。[只读实机输出](../local-tests/quest-live/final-observer-solo-training.json)

## 1.0.4 开发期间的废神社单人探索 101

在村庄正常接取探索，进入废神社主营地后一次也没有进帐篷。角色收弓时，任务管理器的状态为 `Play=2`，而猎人的 `isQuestResultAction()` 同时为真。候选版曾受此条件阻挡。修正判断后，已经落盘并排队的梅自动补刷，无需再次操作 mod 文件。[实机判定](../local-tests/quest-live/expedition-gates.json) · [任务时钟跨分钟](../local-tests/quest-live/expedition-quest-clock.json)

| 当前外观 | 头、身、手、腰、腿材质槽 | 头、身、手、腰活动 CHAIN 组 |
| --- | --- | --- |
| 原版 | 1、1、2、1、1 | 1、1、2、2 |
| 梅 | 21、1、6、31、1 | 23、1、15、8 |
| 天狐 | 12、14、3、16、1 | 21、16、16、9 |
| 卸载还原 | 1、1、2、1、1 | 1、1、2、2 |

每步都把五件材质槽名逐项与供测文件或游戏 PAK 对照，并核对四处物理资源和正在模拟的组数。三次更换的坐标均为 (176.32961, 85.04763, 123.90290)，朝向四元数、本地 PlayerData、弓与箭囊、生命和耐力一致。整套换装后游戏生成新的猎人显示对象。卸载再输入移动，角色实际走了约 2.10 个水平世界单位。[梅](../local-tests/quest-live/expedition-mei.jpg) · [天狐](../local-tests/quest-live/expedition-fox.jpg) · [卸载](../local-tests/quest-live/shrine-quest-a-stock-final.json) · [移动](../local-tests/quest-live/shrine-stock-can-walk.json)

原版 Lua 前置由本机现有的姿态修复 v2 提供。穿梅时单改骨架 JSON，原猎人头骨局部 Y 由 0.05474756 变为 0.07974756 并还原。单改手甲 CHAIN，原组件的活动组和资源组均完成 15 → 14 → 15。两次操作中猎人和五个部件的对象标识均一致。[头骨](../local-tests/quest-live/shrine-json-b.json) · [手甲 14 组](../local-tests/quest-live/shrine-chain14.json)

同一探索还测了两种情形。猎人正常拔弓后装梅，原猎人保持拔刀、手甲保留 2 组。正常按一次收刀键，未再改动文件，排队的五件自动补刷到梅。随后进帐篷改用太刀「凶刀【催花雨】」，出帐后再换天狐、卸载、冷装梅、卸载。每一步均核对五件材质槽和四处实际组数。太刀、刀鞘、位置和朝向保持一致。实测太刀练气为零。[拔刀等待](../local-tests/quest-live/shrine-drawn-pending.json) · [收刀后装梅](../local-tests/quest-live/shrine-deferred-mei.json) · [帐篷外太刀穿天狐](../local-tests/quest-live/shrine-ls-fox.json) · [太刀冷装梅](../local-tests/quest-live/shrine-ls-cold-mei.json)

## 1.0.4 玩家包的 FirstNatives 复测

这一轮单人实测使用的 DLL SHA-256 为 `bcfa49e03a7ece70fa9849f5ab7d3d5f604898a81b67389a3ef2ee3f15df8330`。独立启用 FirstNatives，关闭 REFramework 的 LooseFileLoader，正常读档进入修炼场（区域 5）。「凶刀【催花雨】」太刀从原版安装梅、切换天狐、卸载回原版。每步头骨的基础和当前 Y 均符合目标，五件材质与四处实际 CHAIN 均匹配。三步前后位置、完整朝向、刀和刀鞘、PlayerData、生命及耐力一致。[训练场画面](../local-tests/quest-live/firstnatives-training-longsword-mei.jpg) · [天狐](../local-tests/quest-live/first-training-ls-fox.json) · [卸载](../local-tests/quest-live/first-training-ls-restored.json)

整套安装完成后再单改 FirstNatives 影骨，原猎人、五个原部件保持不变，头骨 Y 完成 0.05474756 → 0.07974756 → 0.05474756。单改手甲物理时同一组件的物理和资源组数完成 15 → 14 → 15。[影骨 B](../local-tests/quest-live/first-ls-shadow-b.json) · [还原 A](../local-tests/quest-live/first-ls-shadow-final-a.json) · [14 组](../local-tests/quest-live/first-ls-chain14.json)

通过训练场装备箱换成大剑「凶剑【丛云】」，主武器为 `G_Swd125`，没有副武器对象。大剑也完成了原版 → 梅 → 天狐 → 原版。随后在集会所正常单人受理「雪鬼兽来了」10708，冰封群岛，重新在主营地帐篷外完成同样三步，未打开装备箱。任务号、地图、PlayerData、大剑、朝向、水平位置、生命和耐力保持一致。四处实穿 CHAIN 及所有材质槽均与文件一致。[训练场卸载](../local-tests/quest-live/first-gs-stock.json) · [冰封群岛穿梅](../local-tests/quest-live/goss-10708-greatsword-mei.jpg) · [穿天狐](../local-tests/quest-live/goss-10708-greatsword-fox.jpg) · [还原](../local-tests/quest-live/goss-first-gs-restored.json)

在同一任务继续正常行走至 1 区。玩家和 FieldZone 均报告不在营地、当前区块 1、非安全区。树木遮挡镜头使玩家暂时不可见时安装梅，离开遮挡后同一请求自动补刷。再在 1 区霜降草旁切天狐、卸载，两次均校验了五件材质、骨架与四处 CHAIN。[场地区块与营地标志](../local-tests/quest-live/goss-normal-zone1.json) · [1 区穿梅](../local-tests/quest-live/goss-10708-field-mei.jpg) · [1 区天狐](../local-tests/quest-live/goss-field-fox.jpg) · [1 区还原](../local-tests/quest-live/goss-zone1-vanilla.json)

整套重建的边界可在训练场大剑快照中观察到。游戏沿用了同一个 PlayerData，采样的 80 个数值相同；新猎人对象的 `_R_VitalTimer` 和 `_CheckEquipSkill209Timer` 在重建时重新初始化。带剩余时长的技能、非零练气、储瓶和弹种余量需要按武器实际验证。[原生状态交接快照](../local-tests/quest-live/first-training-gs-succession.json)

## 1.0.4 训练场的整套模型重建

同一名女 279 猎人在修炼场装备箱选用存档里实际持有的武器，关箱后在原地依次安装梅、切天狐、卸载。每种武器留存四份快照，逐项比较五件材质槽名、头骨局部 Y、四处 CHAIN 的资源组数与活动组数。56 份快照里，同一武器在三次外观变化前后的水平位移均为零，PlayerData、生命、耐力、主副武器对象名称均匹配。整套刷新会产生新的显示对象。[14 种武器的逐项记录](../local-tests/quest-live/training-14-verified.json)

第一轮在 FirstNatives 独立加载时测试了大剑、太刀。在玩家原装 Lua Bone System 姿态修复 v2 下测试了斩斧、轻弩、重弩、大锤、铳枪、长枪、片手剑、双剑、狩猎笛、盾斧、操虫棍、弓。盾斧和操虫棍按实机猎人类确认，武器编号分别为 11 和 12。收尾用装备箱核对了 215 格的弓「赤绝飞翼老人星」，同名的 56 格副本没有装备。[12 种武器详细读数](../local-tests/quest-live/matrix-v2-46840/summary.json) · [装备箱还原](../local-tests/quest-live/matrix-v2-46840/restored-bow-inventory.json)

1.0.4 玩家包的 DLL SHA-256 为 `c7fe9227cfe6aabdcb24f225931cc3c7fe21f9481598003411ae4d9f252202e7`。同一个 DLL 分别在独立 FirstNatives（REF 松散加载关闭）和原版 Lua Bone System 姿态修复 v2（REF 松散加载开启，FirstNatives 已移出）下，从存档逐一选用全部 14 种武器。每次选用武器后先关装备箱，再在场上安装、切换和卸载。两轮共 28 组、112 份实机快照、84 次变更。独立校验按原件及 mod 文件内的名称和顺序逐槽比较，四处 CHAIN 同时检查资源组数和活动组数，核对实际头骨三轴、猎人数据及主副武器。训练场最大水平位移为零。[两种前置的合并验收](../local-tests/quest-live/matrix-D-audit.json) · [FirstNatives 装备记录](../local-tests/quest-live/matrix-first-final/summary.json) · [原版 Lua 装备记录](../local-tests/quest-live/matrix-lua-final/summary.json)

## 1.0.4 在水没林限时狩猎中的复测

村三星「被毒雾侵蚀的水没林」任务号 308，地图 3，50 分钟讨伐毒狗龙王。使用最终 DLL 和独立的 FirstNatives，从原版读档、接任务、出发，在主营地帐篷外完成原版 → 梅 → 天狐 → 原版。每一步的五件实际槽名、四处 CHAIN、头骨基础与当前坐标均符合预期。任务实例、PlayerData、215 格弓及箭囊、朝向、生命和耐力一致，猎人的水平位移为零。[水没林穿梅](../local-tests/quest-live/final-forest-mei.jpg) · [天狐](../local-tests/quest-live/final-forest-bow-fox.json) · [卸载回原版](../local-tests/quest-live/final-forest-bow-restored.json)

留在同一场任务中，只改影骨时，原猎人的头骨基础和当前 Y 都完成 0.05474756 → 0.07974756 → 0.05474756。只改手甲 CHAIN 时，原组件的资源与活动组数都完成 15 → 14 → 15。猎人和五个既有部件的对象标识从头到尾相同。[影骨 B](../local-tests/quest-live/final-forest-shadow-B.json) · [手甲 14 组](../local-tests/quest-live/final-forest-chain14.json) · [还原 15 组](../local-tests/quest-live/final-forest-chain15.json)

## 1.0.4 在冰封群岛的复测

重新读「明月」存档，以最终 DLL、原版 Lua Bone System v2、215 格弓「赤绝飞翼老人星」单人受理 10708。在主营地帐外完成原版 → 梅 → 天狐 → 原版，每一阶段实际装备仍是 215 格、相同弓与箭囊。同一任务实例中，位置、朝向、生命及耐力稳定。穿梅时单改 Lua JSON，原猎人头骨 Y 由 0.05474756 变为 0.07974756，再回到 0.05474756；单改手甲 CHAIN 时原组件实际完成 15 → 14 → 15，两项均保留五件部件对象。[单改 JSON](../local-tests/quest-live/final-goss-json-B.json) · [单改 CHAIN](../local-tests/quest-live/final-goss-chain14.json) · [卸载后的五件实穿](../local-tests/quest-live/final-goss-bow-restored.json) · [任务与箱位记录](../local-tests/quest-live/final-goss-bow-player-restored.json)

现场已还原供测外观文件和附加 JSON，临时测试脚本停止后移除。游戏在重新接取的雪鬼兽任务主营地交回。

## 1.0.4 开发期间的进程退出

最初的雪鬼兽任务中，尝试在独立对象上创建单件手甲时，游戏进程退出，原任务进度中断。随后交付的 1.0.4 玩家包采用游戏正式的整套装备重建。后来重新接取的 10708 单人验证任务，在普通 1 区完成卸载、读回原版并确认猎人可操作后，测试脚本请求打开开始菜单，游戏在显示放弃确认前退出。这条菜单请求也只用于测试。日志记录了重建时的关节读取异常，当前没有对应的退出转储能确定第二次退出的原因。[第二次退出前的框架日志](../local-tests/quest-live/first-48220-framework.log) · [监听日志](../local-tests/quest-live/first-48220-quest-watcher.log)
