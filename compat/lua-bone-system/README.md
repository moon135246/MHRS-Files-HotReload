# 崛起 LUA Bone System 姿态修复 v2 的热加载兼容包

此包供使用 LUA Bone System 的玩家安装。退出游戏后，把单独兼容包里的 `reframework` 合并到崛起目录。包中包含更新后的 `reframework/autorun/LuaBoneSystem.lua` 和原版的男、女两份基础姿态。原来的 Enable、Bind 和 UpdateMotion 姿态修复继续使用。FirstNatives 模式使用自己的加载器。

热加载 DLL 的监听器读取 `reframework/data/LUABoneSystem/custom` 里的男、女头、身、手、腰、腿 JSON。安装工具写完文件后，监听器用两次一致的元数据、写入者关闭状态和文件内容验证本次变化。格式损坏时保留已经采用的姿态。删除文件也会通知当前穿戴这件装备的猎人。

监听器在 `reframework/data/MHRS-Files-HotReload/bone-profiles.json` 中原子发布当前部件名和 SHA-256。Python 入口是 `BoneProfiles(game, channel).poll()`，需为每个监听会话创建一个实例，在现有循环里调用。它自行限制扫描频率。文件含 `version`（当前为 1）和 `profiles`（小写部件名到十六进制摘要的映射）。快照覆盖整个 custom 目录，所以消费者可以跨过中间通知。

前置脚本在原有 UpdateMotion 回调中约每 0.55 秒检查一次通知。只有当前穿戴的部件受影响时，才重选 JSON、失效相应的腿部 IK 初始化结果并更新姿态。脚本沿用原来的关节写入阶段，并在每个玩家实例上单独处理。

在项目根目录运行以下命令可复现独立前置 ZIP。构建工具校验原 Lua 及两份基础姿态的 SHA-256，兼容改动在本目录的 `profile_changes.lua` 以及构建工具的替换位置可见。

```powershell
python tools/build_lua_bone_compat.py '..\崛起自定义骨架\LUA Bone System(崛起)-姿态修复-v2.zip' '..\崛起自定义骨架\LUA Bone System(崛起)-姿态修复-v2-热加载兼容.zip'
```
