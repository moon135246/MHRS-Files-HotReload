@echo off
setlocal
set "MHR_NATIVE=%~dp0.."
set "MHR_PYSDK=%~f1"
set "MHR_REFSRC=%~f2"
set "MHR_ZSTD=%~f4"
cd /d "%~f3" || exit /b 1
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "MHR_VS=%%i"
if not defined MHR_VS exit /b 1
call "%MHR_VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
rc /nologo payload.rc || exit /b 1
cl /c /nologo /O2 /MT /DWIN32 /DPy_NO_ENABLE_SHARED /DPy_BUILD_CORE /D_Py_HAVE_ZLIB /I"%MHR_PYSDK%\install\include" config.c || exit /b 1
cl /c /nologo /O2 /MT /DPy_NO_ENABLE_SHARED /I"%MHR_PYSDK%\install\include" /I"%MHR_ZSTD%\lib" "%MHR_NATIVE%\embedded\pak_codec.c" "%MHR_ZSTD%\build\single_file_libs\zstddeclib-in.c" || exit /b 1
if not exist lua mkdir lua
pushd lua
cl /c /nologo /O2 /MT "%MHR_REFSRC%\dependencies\lua\src\*.c" || exit /b 1
lib /nologo /out:lua.lib *.obj || exit /b 1
popd
cl /c /nologo /O2 /MT /std:c++17 /EHsc /DMHRS_EMBEDDED_WATCHER /DPy_NO_ENABLE_SHARED /I. /I"%MHR_PYSDK%\install\include" /I"%MHR_REFSRC%\dependencies\lua\src" /I"%MHR_REFSRC%\include" "%MHR_NATIVE%\embedded\plugin.cpp" "%MHR_NATIVE%\arm_material.cpp" "%MHR_NATIVE%\request_watch.cpp" || exit /b 1
link /nologo /dll /out:mhrs_hotreload.dll /opt:ref /opt:icf plugin.obj arm_material.obj request_watch.obj config.obj pak_codec.obj zstddeclib-in.obj payload.res lua\lua.lib ^
 "%MHR_PYSDK%\build\core\python312.lib" "%MHR_PYSDK%\build\extensions\_ctypes\_ctypes.lib" ^
 "%MHR_PYSDK%\build\extensions\_uuid\_uuid.lib" "%MHR_PYSDK%\build\extensions\unicodedata\unicodedata.lib" ^
 "%MHR_PYSDK%\build\lib\libffi.lib" version.lib ws2_32.lib ole32.lib oleaut32.lib user32.lib pathcch.lib rpcrt4.lib advapi32.lib shell32.lib bcrypt.lib shlwapi.lib || exit /b 1
if /i "%~5"=="verify" (
    cl /nologo /O2 /MT /std:c++17 /EHsc /I"%MHR_REFSRC%\dependencies\lua\src" /I"%MHR_REFSRC%\include" "%MHR_NATIVE%\embedded\test_host.cpp" /Fe:test_host.exe /link lua\lua.lib || exit /b 1
)
