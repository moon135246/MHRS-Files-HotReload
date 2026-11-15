@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "MHR_VS=%%i"
if not defined MHR_VS exit /b 1
call "%MHR_VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist "..\reframework\data\MHRS-Files-HotReload" mkdir "..\reframework\data\MHRS-Files-HotReload"
if /I "%~1"=="request-watch" goto request_watch
cl /nologo /std:c++17 /W4 /EHsc /O2 /MT /LD arm_material.cpp /Fobuild\arm_material.obj /link /OUT:build\arm_material.dll /IMPLIB:build\arm_material.lib
if errorlevel 1 exit /b 1
copy /Y "build\arm_material.dll" "..\reframework\data\MHRS-Files-HotReload\arm_material.dll" >nul || exit /b 1
:request_watch
cl /nologo /std:c++17 /W4 /EHsc /O2 /MT /LD request_watch.cpp /Fobuild\request_watch.obj /link /OUT:build\request_watch.dll /IMPLIB:build\request_watch.lib
if errorlevel 1 exit /b 1
copy /Y "build\request_watch.dll" "..\reframework\data\MHRS-Files-HotReload\request_watch.dll" >nul
