# 第三方署名

## MHWS-Files-HotReload · Stellar（AleksKavil）

感谢 Stellar 公开《怪物猎人：荒野》热加载工具的源码。开发崛起版时，我们参考了该项目的目录变更监听、资源引用追踪，以及等待依赖就绪后刷新当前场景对象的做法。[上游仓库](https://github.com/AleksKavil/MHWS-Files-HotReload) · [开发时参考的版本](https://github.com/AleksKavil/MHWS-Files-HotReload/tree/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08)

荒野版暂存旧资源、按原路径请求新资源、刷新已绑定的 Mesh，并按文件差异保留运行时材质参数的流程，为崛起版处理同路径覆盖提供了具体参照。[资源重载实现](https://github.com/AleksKavil/MHWS-Files-HotReload/blob/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08/src/hotreload.cpp)

Copyright (c) 2026 Stellar。上游项目采用 MIT License。[上游许可原文（随包副本）](licenses/MHWS-Files-HotReload-LICENSE.txt)

## REFramework · praydog 及贡献者

感谢 REFramework 提供崛起版使用的 Lua 脚本运行环境、资源 API、对象反射接口和 LooseFileLoader。[REFramework 项目](https://github.com/praydog/REFramework)
