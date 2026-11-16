# 第三方署名

## MHWS-Files-HotReload · Stellar（AleksKavil）

感谢 Stellar 公开《怪物猎人：荒野》热加载工具的源码。开发崛起版时，我们参考了该项目的目录变更监听、资源引用追踪，以及等待依赖就绪后刷新当前场景对象的做法。[上游仓库](https://github.com/AleksKavil/MHWS-Files-HotReload) · [开发时参考的版本](https://github.com/AleksKavil/MHWS-Files-HotReload/tree/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08)

荒野版暂存旧资源、按原路径请求新资源、刷新已绑定的 Mesh，并按文件差异保留运行时材质参数的流程，为崛起版处理同路径覆盖提供了具体参照。[资源重载实现](https://github.com/AleksKavil/MHWS-Files-HotReload/blob/e3ef3e067bfed2da5c1a1adac79c55fe1dbaaa08/src/hotreload.cpp)

Copyright (c) 2026 Stellar。上游项目采用 MIT License。[上游许可原文（随包副本）](licenses/MHWS-Files-HotReload-LICENSE.txt)

## REFramework · praydog 及贡献者

感谢 REFramework 提供崛起版使用的 Lua 脚本运行环境、资源 API、对象反射接口和 LooseFileLoader。[REFramework 项目](https://github.com/praydog/REFramework)

## 单 DLL 玩家包

从本机崛起 PAK 读取已安装资源使用静态链接的 Zstandard 1.5.7 解压器（BSD 许可）。PAK 格式参考 Ekey 的 REE.PAK.Tool 与 NSACloud 的 RE Asset Library。安装包含 Zstandard 的许可。[Zstandard 1.5.7](https://github.com/facebook/zstd/releases/tag/v1.5.7) · [REE.PAK.Tool](https://github.com/Ekey/REE.PAK.Tool) · [RE Asset Library](https://github.com/NSACloud/RE-Asset-Library)

插件使用 REFramework 的 MIT 许可插件接口，以及该项目配套的 Lua 5.4.3 源码与宿主 Lua 状态交互。[REFramework 源码版本](https://github.com/praydog/REFramework/tree/c4b1314820d20255febf7834903e8cedb669b49c) · [Lua 许可](https://www.lua.org/license.html)

资源监听使用静态 CPython 3.12.2，由 python-build-standalone 的 20240224 Windows x64 发行包提供。构建将使用的 Python 模块冻结进 DLL，并禁用该 SDK 的 ctypes 对宿主 EXE 的 C API 加载。实现包含 CPython、libffi、zlib、Unicode 数据，以及 SDK 为 UUID 模块列出的 libuuid 许可。相应许可与 Lua、REFramework 的版权声明随单 DLL 安装包置于本文件旁的 `licenses` 目录。[静态 SDK](https://github.com/astral-sh/python-build-standalone/releases/tag/20240224) · [CPython](https://www.python.org/)
