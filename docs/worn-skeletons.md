# 启动前已穿自定义外观的实机记录

本文的 `local-tests/` 链接指向开发机保存的原始回执。各项实测读数已列在正文中。

## 原猎人的五个防具挂点

1.0.6 的整套替换使用崛起的 `PlayerManager.instantiatePlayerParts`。正常进出训练场的记录显示，部件工厂以猎人 Transform 为父节点创建装备，`PlayerMaterialParts.start` 随后把自己登记到猎人材质控制器的相应槽位。在已可操作的弓猎人身上额外创建同款原版腿甲和手甲，两件都自然接管了槽位。新手甲的两组 CHAIN 开始模拟。撤下测试件后，游戏清空槽位，经 `addMaterialParts` 登记的原件恢复穿戴。[游戏自然装配](../local-tests/mount-live/normal-trip.json) · [腿甲](../local-tests/mount-live/leg-cycle.json) · [手甲](../local-tests/mount-live/arm-cycle.json)

插件按实际装备索引预热防具，保留旧件，等新件在原控制器登记，再核对新 MESH、材质槽、物理资源和活动组数。旧件退场时可能清空刚登记的槽，插件会在同一个控制器上重新登记本次新件。FirstNatives 改变基础姿态时，插件先在原猎人上更新影骨，让已绑定的 CHAIN 恢复，再装配新模型。Lua Bone System 使用玩家原有脚本，由本插件刷新配置缓存。

在 1.0.6 的训练场验收中，FirstNatives 和玩家原装 Lua Bone System 各用十四类武器完成了原版 → 梅 → 天狐 → 原版。每种前置的 42 次切换均保留原猎人、原主武器及其副件。每次换装逐槽核对新部件的父 Transform、原材质控制器的登记、MESH、MDF 和四处实际运行的 CHAIN。FirstNatives 检查头骨的基础与当前局部位置，Lua Bone System 则检查前置所调整的当前局部位置。两轮共 116 次染色采样，覆盖每类武器的四种外观状态及每轮首末的原弓。每件防具按其存档槽号对照启用色，核对组件中的两路颜色以及实际材质的 `S_col_R` 和 `S_col_G`。[FirstNatives 十四类逐项记录](../local-tests/mount-live/i-first-14/summary.json) · [原装 Lua 十四类逐项记录](../local-tests/mount-live/i-lua-14/summary.json) · [盾斧切天狐的挂点与物理](../local-tests/mount-live/i-first-14/11-slot29-fox.json) · [同一盾斧的材质染色](../local-tests/mount-live/i-first-14/11-slot29-fox-dye.json)

实机按身体、手、腰、腿、头排列，记录到以下局部关节数和运行中的 CHAIN 组数。运行在单人训练场的原版 Lua Bone System 与单人废神社探索任务 101 的 FirstNatives 得到相同结果。每套只有五个对应的直接子对象，槽位、材质控制器和父 Transform 一致，模拟均已启用且解冻。梅的身体沿用原版一组 CHAIN，所用 MESH 省略了原版的 `body_chain_end`。手甲则能在梅读到 `WstBone_152`，在天狐读到 `ArmBone_157`。[训练场原版](../local-tests/mount-live/b-off.json) · [训练场梅](../local-tests/mount-live/b-mei.json) · [训练场天狐](../local-tests/mount-live/b-fox.json)

| 外观 | 五件局部关节数 | 五件活动 CHAIN 组数 |
| --- | --- | --- |
| 原版女 279 | 27 / 56 / 22 / 16 / 6 | 1 / 2 / 2 / 无 / 1 |
| 梅 | 141 / 174 / 118 / 141 / 145 | 1 / 15 / 8 / 无 / 23 |
| 天狐 | 154 / 128 / 108 / 141 / 148 | 16 / 16 / 9 / 无 / 21 |

FirstNatives 实测关闭 REFramework 松散文件加载，启动前即安装梅。从村中读档进入废神社单人探索后，切天狐、关闭外观、再装梅均保持同一猎人、控制器、武器和箭囊。卸载时根骨 `Head_00.BaseLocalPosition.y` 回到 0.12800001，再装梅时回到 0.05474756。[读档](../local-tests/mount-live/c-first-preinstalled.json) · [任务内切天狐](../local-tests/mount-live/mount-c-quest-fox.json) · [卸载](../local-tests/mount-live/mount-c-quest-off.json) · [再装梅](../local-tests/mount-live/mount-c-quest-mei.json)

在同一场废神社探索中，启动前穿梅，随后连续切天狐、卸载、装梅、卸载、装梅、切天狐、卸载。七次都在同一猎人上完成了五槽交接，共采到 3,857 帧，猎人根对象隐藏 0 帧。从最后一份原生资源落盘到读回整套新外观为 2.95–3.83 秒，中位数 3.20 秒。计时用的是开发候选 G；它同时核对物理组数和可见外观，每次还留出两秒复读。卸载后原脸与头发保留各自的原对象并恢复绘制，结算特写显示白色发髻、脸和位于额头的金冠。该序列覆盖了曾在第二次卸载时卡住的旧部件回收问题。[七次采样](../local-tests/mount-live/g-first-quest-summary.json) · [第二次卸载的五件与脸发](../local-tests/mount-live/g-q4-off.json) · [结算特写](../local-tests/mount-live/g-first-quest-closeup-stock.jpg)

同一次结算特写也暴露了独立的装备染色问题。游戏正常穿戴时，原版披风使用存档里的红色。只换预制体会让新材质使用文件默认色，五件外观的材质名、关节、CHAIN 和脸发仍能全部通过校验。训练场把梅卸回原版后，角色的 10 个部件颜色通道、实际着色器的 12 个通道均与存档不符。保留原猎人，用新部件自己的 `setSymbolColor` 和 `updateSymbolColor` 应用该槽已启用的两路配色，10 个部件通道和 12 个着色器通道全部恢复。读取目标为实际材质的 `S_col_R` 和 `S_col_G`。头、身、手、腰、腿的存档顺序与渲染槽的顺序不同。[正常穿戴](../local-tests/mount-live/g-dye-stock-natural.json) · [恢复前](../local-tests/mount-live/g-dye-training-before.json) · [恢复后](../local-tests/mount-live/g-dye-training-after.json) · [训练场红披风](../local-tests/mount-live/g-dye-training-restored.jpg)

同一个 1.0.6 单 DLL 在 FirstNatives 模式下，又用太刀重测了单人废神社探索。游戏启动和进入任务时均为原版，固定营地猎人后完成装梅、切天狐、卸载。三段从最后一个文件落盘到可见资源就绪分别为 3.30、3.49、3.01 秒，1,629 个采样帧中猎人根始终可见。原版、梅、天狐分别读回 12、120、92 路实际着色器颜色，均与保存的装备色相符。卸载后的营地背面和结算正面都恢复了红披风、白发及额饰。正常结算回村后，在新场景的原猎人上又装梅、卸载，同样保留该猎人、装备染色和武器。[任务内梅](../local-tests/mount-live/i-first-q101-1-mei.json) · [天狐](../local-tests/mount-live/i-first-q101-2-fox.json) · [卸载](../local-tests/mount-live/i-first-q101-3-none.json) · [结算近景](../local-tests/mount-live/i-first-101-closeup.jpg) · [回村后再次卸载](../local-tests/mount-live/i-first-postquest-village-2-none.json)

另一次用玩家原装 Lua Bone System 和 REFramework LooseFileLoader，启动前装好梅。存档选择画面已经穿梅；进村后直接切天狐再卸载，弓、箭囊和村庄猎人均保留原对象。三种外观下 `Head_00.BaseLocalPosition.y` 始终为 0.12800001；原 Lua 脚本作用于当前局部姿态，穿梅和天狐时 `LocalPosition.y` 都为 0.05474756，卸载后恢复为 0.12800001。两次切换的 1,630 个采样帧中猎人根始终可见。[存档选择画面](../local-tests/mount-live/i-lua-cold-mei-selection.jpg) · [读档后的五件挂点](../local-tests/mount-live/i-lua-cold-root.json) · [村内切天狐](../local-tests/mount-live/i-lua-cold-village-1-fox.json) · [村内卸载](../local-tests/mount-live/i-lua-cold-village-2-none.json)

同一前置在水没林毒狗龙王任务 308 中用操虫棍完成原版 → 梅 → 天狐 → 原版。四次读数中，猎人根、操虫棍和猎虫的地址保持一致，头骨的基础与当前局部位置符合村内冷启动读数。五件部件的局部关节和活动 CHAIN 组数均与上表相符。梅、天狐、卸载后分别在 120、92、12 个实际着色器通道读回存档色。卸载后的结算画面显示原脸、白色发髻与红披风。[水没林原版猎人](../local-tests/mount-live/i-lua-308-root.json) · [天狐的关节与物理](../local-tests/mount-live/i-lua-q308-2-fox.json) · [卸载后的染色](../local-tests/mount-live/i-lua-q308-3-none-dye.json) · [结算画面](../local-tests/mount-live/i-lua-308-result-stock.jpg)

测试时让同一名猎人停在营地或村里。修改一个可读回的骨骼坐标或物理组数，再恢复文件，比较两个方向的读数、角色和部件身份。梅和天狐随附的五份骨骼 JSON 在两套之间相同，套装专用的 `f_shadow.mesh` 也相同。下面的单骨测试另外制作了只改变 `Head_00` 局部 Y 的对照文件。

## 荒野 file_hotreload.v1.0.1

- 在营地启动原版插件和 BoneSystem.dll，猎人已穿 003 外观。将现用的 `ch03_003_0012.chain2.14` 从 46 组改为 45 组，然后还原。原 Chain 组件的资源组数和正在模拟的组数都读到 46 → 45 → 46。
- 修改同一套外观的 `SF_Shinano.fbxskel.7`。原 `CustomSkeleton` 组件取得新的 holder，原版日志同时记录 `CustomSkeleton` 与 `RetargetRig` 的场景绑定。此项记录了消费者绑定，未测该轮猎人的实际关节位移。
- 单独启用 LUA Bone System v1.41 后，在同一名猎人身上只改骨架 JSON。`Head` 的局部 Y 从 0.02693639 到 0.05193639，再回到 0.02693639，基础坐标保持 0.06。JSON 由该 Lua 前置在 `UpdateMotion` 中重新读取。

## 崛起 Lua Bone System，玩家原脚本

1.0.3 将适配放在热加载 DLL 中。在 REFramework 加载玩家的 `LuaBoneSystem.lua` 时，插件识别该脚本登记的动画回调和持有的缓存。监听器等文件写完，验证骨骼偏移，按内容哈希发布一批 JSON。插件只让使用对应部件的猎人重新选择配置。设置姿态及初始化 IK 仍由玩家安装的脚本在原有动画阶段执行。

Steam 崛起 16.0.2.0，REFramework LooseFileLoader 开启，姿态修复 v2 原脚本 SHA-256 为 `E637EEF9298F4DBAFCF8293EA418CBE1B2BC699EF465DF6FF9663F4560BA10B7`。使用 1.0.2 和这份原脚本时，文件摘要改变后，同一猎人的头骨仍停在 0.05474756。换用 1.0.3 后，启动时未装外观，在桥头依次安装梅、覆盖为天狐、卸载回原版，各步都自动完成；五件装备的材质槽名与对应 MDF 一致，四处正在模拟的 CHAIN 组数与文件一致。四张截图取自同一机位。[原版](../local-tests/stock-lua-live/stock.jpg) · [梅](../local-tests/stock-lua-live/mei.jpg) · [天狐](../local-tests/stock-lua-live/fox.jpg) · [卸载](../local-tests/stock-lua-live/stock-return.jpg)

穿梅并等整套装备稳定后，仅覆盖五份 JSON，`Head_00.LocalPosition.y` 从 0.05474756 变为 0.07974756，恢复原文件后回到 0.05474756。移走五份 JSON 后为 0.12800001，再放回为 0.05474756。整个序列中角色根及全部五个部件地址一致，手甲保持 15 组。[覆盖后的关节](../local-tests/stock-lua-live/v2-mei-B-steady.json) · [仅卸载 JSON](../local-tests/stock-lua-live/v2-mei-no-profiles.json) · [重新安装 JSON](../local-tests/stock-lua-live/v2-mei-reinstalled-profiles.json)

另一份未改动的早期前置使用 `PrepareRendering`，SHA-256 为 `F11B409AD4C83C2A53F733441FA1C269789105A19DD83816E9F5A0FC5740F574`。预装梅启动，在这个回调中读到相同的覆盖、删除和重装结果，猎人及五个部件身份保持不变。进入训练场后，弓猎人的原对象也完成了 0.05474756 → 0.07974756 → 0.05474756。[早期原版覆盖](../local-tests/stock-lua-live/legacy-B.json) · [训练场弓猎人](../local-tests/stock-lua-live/legacy-training-json-B.json)

测试输入暂时不可用时，先用测试接口锁住村庄本地猎人的输入，再将梅覆盖为天狐。仍穿梅时读回 `isInput=false`，日志已记录待刷新的部件。仅释放输入后，插件重新检查当前穿着，五件装备都取得天狐对应的材质槽和 CHAIN，手甲从 15 组变为 16 组。[输入锁期间](../local-tests/stock-lua-live/legacy-while-locked.json) · [释放后的五件装备](../local-tests/stock-lua-live/legacy-fox-after-release.json)

### 1.0.2 的旧版适配记录


使用姿态修复 v2 的热加载兼容版，启用 REFramework LooseFileLoader，启动前装好梅。在村内只更新五份配置中的 `Head_00` 并恢复。实际局部 Y 为 0.05474756 → 0.07974756 → 0.05474756。角色根和五个穿戴部件始终是同一批对象，游戏基础骨架的该关节保持原值。插件只在完整配置内容变化时通知前置，前置在原有姿态和 IK 更新流程中消费新配置。

## 崛起 FirstNatives 和单件物理

单独启用 FirstNatives 23.2.8，关闭 REFramework LooseFileLoader，移出 Lua Bone System，启动前装好梅。在炎火村的同一名猎人上，替换 `player/mod/f/pl279/f_shadow.mesh.2109148288`。现有根 Transform 的 `Head_00.BaseLocalPosition.y` 与 `LocalPosition.y` 均为 0.05474756 → 0.07974756 → 0.05474756，五个装备部件保持原对象。重载逐项核对关节名称、父节点和基础局部位置。当前支持与原版拓扑和关节局部旋转、缩放一致的 279 示例骨架。其他层级或关节基底的改动留待游戏正常创建。

在同一个 FirstNatives 进程中，只改梅手甲 CHAIN 的组数并恢复。同一个手甲物理组件读回的资源组数与实际模拟组数均为 15 → 14 → 15，另外三件始终为 1、23、8 组。

## 1.0.2 在炎火村的整套模型重建

在启动前装好梅，开启 FirstNatives 并关闭 REFramework LooseFileLoader。进入村后在桥头换天狐，再换回梅，最后卸载外观。每次逐项比对五件装备的全部材质槽名，以及四个 CHAIN 组件的资源组数和模拟组数。

| 实际身上外观 | 手臂 | 身体 | 头 | 腰 | 基础骨骼 Head_00 Y |
| --- | ---: | ---: | ---: | ---: | ---: |
| 启动前的梅 | 15 | 1 | 23 | 8 | 0.05474756 |
| 运行中换天狐 | 16 | 16 | 21 | 9 | 0.05474756 |
| 换回梅 | 15 | 1 | 23 | 8 | 0.05474756 |
| 卸载到原版 279 | 2 | 1 | 1 | 2 | 0.12800001 |

梅和天狐的手、身、头、腰用了不同的物理末端骨。整套换装调用游戏的本地装备模型重建，等新模型就绪，再交还原猎人的 `AreaMoveFlag`。四段采样的水平坐标均为 X −1498.89294、Z −1465.65100。角色可见且可操作，猎人和装备组件地址随重建变化。另一次连续重建后通过实际移动输入走了 3.124 个世界单位，25 次采样均可见。此路径用于状态就绪、可操作的村庄本地猎人。

用 FirstNatives 重新启动时，游戏目录中没有这两套外观，监听基线是 8 个原有文件。进村后安装梅、换成天狐、卸载回原版 279。四段 `Head_00.BaseLocalPosition.y` 为 0.12800001 → 0.05474756 → 0.05474756 → 0.12800001，各套的材质槽和物理组与上表一致。游戏有时会在重建期间重新打开通用的 `f_shadow.mesh`。插件同时淘汰旧通用缓存，重建后核对 79 个关节，必要时在新猎人上重新绑定已准备好的套装影骨。

在单独启用 Lua 前置、REFramework LooseFileLoader 开启的干净进程里也完成原版 → 梅 → 天狐 → 原版。五件装备的所有材质槽与文件一致，物理组数与上表一致。穿梅时单独修订 JSON，同一个猎人和五个部件保留，头骨局部 Y 从 0.05474756 到 0.07974756 再还原。同一手甲随后完成 15 → 14 → 15 组。卸载后身体骨架的基础和当前头骨局部 Y 都恢复到 0.12800001。

1.0.2 玩家包采用单个 `mhrs_hotreload.dll`，SHA-256 为 `a3156a25511ea9bc8a92eaa68711fcd598621ed8863cf1050ca9a3e2d5932b85`。同一 DLL 在 FirstNatives 干净启动后实测原版 → 梅 → 天狐 → 原版，另在 Lua 前置下实测预装梅 → 天狐 → 原版。最终两份监听日志均完成处理，未出现重试或拒绝。工作区保留了同一桥头的[原版画面](../local-tests/skeleton-live/f-first-stock.jpg)、[梅](../local-tests/skeleton-live/f-first-mei.jpg)、[天狐](../local-tests/skeleton-live/f-first-fox.jpg)及[卸载后读数](../local-tests/skeleton-live/f-first-stock1.json)。

## 1.0.3 在训练场的整套模型重建

训练场使用 `snow.player.Bow`，和村庄猎人的类型不同。只让游戏重建模型时，五件装备可以读到新模型和 CHAIN，但新猎人会留在不可见且无法操作的状态。插件在收弓站稳后提交重建，核对训练场、玩家索引、PlayerData 和武器，再恢复重建前的 `AreaMoveFlag`。游戏恢复显示和输入后再核验各件装备。

FirstNatives 独立启用、REFramework LooseFileLoader 关闭。先用正常移动输入离开训练场入口，再在收弓状态换装。梅 → 天狐 → 原版三步的水平位置均为 X −517.21393、Z −445.20523，朝向、PlayerData、弓和箭筒相同。手甲模拟组数为 15 → 16 → 2，五件装备所有材质槽均匹配文件；卸载后再次输入移动，猎人又走了 1.14 个世界单位。同期读到耐力 3000、可恢复生命值 150、生命上限 150，本次没有取得当前生命值的独立精确读数。[天狐实穿](../local-tests/stock-lua-live/d-first-fox.json) · [卸载后状态](../local-tests/stock-lua-live/d-control-stock.json) · [移动验收](../local-tests/stock-lua-live/d-walk-after.json)

1.0.3 最终 DLL 在单独启用未经改动的姿态修复 v2 时，训练场也完成原版 → 梅 → 天狐 → 原版。每一步都复核了五件装备全部材质槽和四处物理。穿梅并稳定后，只改 JSON，原猎人头骨从 0.05474756 变为 0.07974756 再还原；接着只改手甲 CHAIN，同一组件从 15 组变为 14 组再还原。整套卸载后猎人仍在刚才停住的位置，输入移动可用。[骨架覆盖](../local-tests/stock-lua-live/e-v2-training-json-B.json) · [手甲 14 组](../local-tests/stock-lua-live/e-v2-training-chain-14.json) · [原地恢复原版](../local-tests/stock-lua-live/e-v2-training-return-stock.json)

在独立的 FirstNatives 进程中，以同一个最终 DLL、空外观启动，再在训练场从原版安装梅、覆盖天狐、卸载回原版，手甲 2 → 15 → 16 → 2 组。穿梅时单改影骨或手甲物理，角色和五个部件保持原对象，头骨基础和当前 Y 都完成 0.05474756 → 0.07974756 → 0.05474756，手甲的资源和模拟组数均完成 15 → 14 → 15。换装前后水平位置 X −517.23383、Z −445.21286、朝向和 PlayerData 一致，最后再以正常输入移动 1.16 个世界单位。[影骨](../local-tests/stock-lua-live/e-first-shadow-B.json) · [手甲物理](../local-tests/stock-lua-live/e-first-14.json) · [卸载原版](../local-tests/stock-lua-live/e-first-training-return-stock.json)

在 1.0.3 中，训练场整套重建仅对本地弓猎人启用。1.0.4 将这条路径扩展到训练场其他武器和实际任务。[任务内验收](quest-equipment.md)

单资源按各自持有组件的机制处理，逐项范围见项目 README。

1.0.3 的 Fluffy 包内仅有一个程序文件 `reframework/plugins/mhrs_hotreload.dll`，SHA-256 为 `3d50eb5a826803723f3828123b8c3354df4419e3afb3d5a0ad4dd0905c295ef9`。

## 崛起水车动作

村内用相同帧数的 MOT 镜像水车转动，再将转动曲线展平，最后卸载文件。对同一水车、同一 Motion 和同一动画层连续采样，每段 48 帧。FirstNatives 下由实际场景物体的世界旋转测得沿 X 轴的角位移依次为 +52.86°、−53.88°、0°、+51.61°。使用 REFramework LooseFileLoader 时为 +56.99°、−56.18°、0°、+57.46°。各阶段的动作末帧均为 239。

在该轮交付的玩家 DLL 上重复四段测试，两种加载器下都再次测得正转、反转、静止和恢复。[FirstNatives 原始采样](../local-tests/skeleton-live/wheel-release-first-43296/summary.json) · [REFramework LooseFileLoader 原始采样](../local-tests/skeleton-live/wheel-release-default-14144/summary.json)

## 在原猎人上换资源

荒野 `file_hotreload.v1.0.1` 的 `refresh_meshes` 按资源路径查找场景中已有的 Mesh。新资源就绪后，它在原组件上调用 `setMesh` 或 `set_Material`，并恢复运行时的材质和部件开关。Chain2、CustomSkeleton 和 RetargetRig 各有自己的绑定步骤。在 003 外观的冷安装记录中，从一件 Mesh 的重载到换绑约 33 毫秒。同一部件的材质依赖 44 项资源（贴图和 MMTR），约 12.49 秒后才完成绑定。单件 Mesh 和整套就绪的时间应分开测量。[荒野实现](https://github.com/AleksKavil/MHWS-Files-HotReload/blob/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08/src/hotreload.cpp) · [003 冷安装日志](../local-tests/cold-install-20261116/wilds-cold.log)

崛起在单人训练场穿梅时，同一手甲的 CHAIN 绑定到游戏原有的零组资源后，在下一帧从 15 个活动组降至 0；绑定回原资源，下一帧恢复 15 组。另一次在清空物理后，尝试在原手甲上换用天狐的模型、材质。游戏进程在写出下一帧记录前退出。最后的采样仍是梅的关节，无法从这份记录确定是哪个调用导致退出。游戏已重新启动并正常读档。1.0.5 对整套切换采用游戏的装备装配流程。[物理清空和恢复](../local-tests/direct-live/empty-mei.json) · [换绑前最后一帧](../local-tests/direct-live/arm-topology-exit.json)

1.0.5 期间的帐篷换装记录中，`PlayerManager.instantiatePlayerParts` 为新猎人逐件装配防具。后续对已在场猎人的单腿甲、手甲和整套实测确认，同一个工厂可以使用原猎人的 Transform，并在原控制器上登记新部件。1.0.6 的整套热加载使用后一条路径。[帐篷正常换装](../local-tests/quest-live/tent-trace.json) · [原猎人手甲的装配与撤下](../local-tests/mount-live/arm-cycle.json) · [太刀任务中卸载后的五个挂点](../local-tests/mount-live/i-first-q101-3-none.json)

1.0.5 玩家 DLL 的 SHA-256 为 `5eb53f5ec7843db3421714ff95f63dd851b089a8f4c5494f4c810e86d00b17ae`。FirstNatives 关闭 REFramework 松散文件加载，在训练场持弓完成原版 → 梅 → 天狐 → 原版。玩家原有的 Lua Bone System 配合 REFramework 松散文件加载，在单人村任务 101 废神社主营地完成同样三步。两次均未进帐篷。游戏实际显示五件目标 MDF 的材质槽，头、身、手、腰的活动 CHAIN 从原版的 1/1/2/2 变为梅的 23/1/15/8，再到天狐的 21/16/16/9，卸载回到原版。每次就绪后五秒再次核对了猎人和穿戴部件。[训练场穿天狐](../local-tests/direct-live/e-first-fox-settled.json) · [实际任务穿天狐](../local-tests/direct-live/e-quest-fox-settled.json)

在上述两种前置和场景中，整套卸载后，插件都记录了五件正在穿戴的原版 PAK MESH。随后单改原版女 279 腿甲的 18 个顶点，再卸载。两次换绑的猎人、五个部件、腿部渲染器、材质资源、六处关节基础姿态以及四个活动 CHAIN 全程一致；腿部 Mesh 底层资源在安装和卸载时分别切换到新一代。目标文件的 SHA-256 与实机已绑定路径对应的来源逐项吻合。实测的几何句柄读数为 0，顶点坐标来自文件核对。[顶点差异](../local-tests/direct-live/leg-vertices/manifest.json) · [FirstNatives 安装后](../local-tests/direct-live/e-first-post-outfit-edited.json) · [Lua 任务内安装后](../local-tests/direct-live/e-quest-post-outfit-edited.json) · [任务内卸载后](../local-tests/direct-live/e-quest-post-outfit-returned.json)

整套耗时从最后一个原件落盘算起，到游戏连续两个动画更新都读回猎人可见、五件材质就绪、四处 CHAIN 的资源组数与活动组数均正确为止。下表每格为一次实机往返中的单步秒数。训练场新旧版本使用相同的弓、Lua Bone System、外观文件和采样器。[计时、组件标识与 CHAIN 读数](../local-tests/direct-live/release-results.json)

| 场景和前置 | 安装梅 | 梅切天狐 | 关闭天狐 |
| --- | ---: | ---: | ---: |
| 1.0.4 训练场，Lua Bone System | 6.73 | 8.96 | 5.61 |
| 1.0.5 训练场，Lua Bone System | 2.73 | 3.25 | 2.62 |
| 1.0.5 训练场，FirstNatives | 2.58 | 3.31 | 2.65 |
| 1.0.5 村探索 101，Lua Bone System | 4.00 | 4.77 | 3.98 |
