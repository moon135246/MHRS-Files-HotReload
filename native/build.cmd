@echo off
setlocal
cd /d "%~dp0"
if not exist build mkdir build
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "MHR_VS=%%i"
if not defined MHR_VS exit /b 1
call "%MHR_VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist "..\reframework\data\MHRS-Files-HotReload" mkdir "..\reframework\data\MHRS-Files-HotReload"
cl /nologo /std:c++17 /W4 /EHsc /O2 /MT /LD /Fobuild\ arm_material.cpp request_watch.cpp /link /OUT:build\mhrs_hotreload.dll /IMPLIB:build\mhrs_hotreload.lib
if errorlevel 1 exit /b 1
copy /Y "build\mhrs_hotreload.dll" "..\reframework\data\MHRS-Files-HotReload\mhrs_hotreload.dll" >nul || exit /b 1
