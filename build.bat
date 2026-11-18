@echo off
rem build.bat [version]   e.g. "build.bat 1.2.0". Without a version it's a "dev" build that never updates itself.
setlocal
cd /d "%~dp0"
set "VERDEF="
if not "%~1"=="" set "VERDEF=/DLW_VERSION=\"%~1\""

where cl >nul 2>nul
if not errorlevel 1 goto :build
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (
    echo Visual Studio C++ tools not found. Install "Desktop development with C++".
    exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

:build
if not exist build mkdir build
fxc /nologo /T vs_4_0 /E VSMain /Fh build\vs.h /Vn g_VSMain src\builtin.hlsl >nul || exit /b 1
fxc /nologo /T ps_4_0 /E PSTex /Fh build\ps_tex.h /Vn g_PSTex src\builtin.hlsl >nul || exit /b 1
fxc /nologo /T vs_4_0 /E VSParticle /Fh build\part_vs.h /Vn g_VSParticle src\particles.hlsl >nul || exit /b 1
fxc /nologo /T ps_4_0 /E PSParticle /Fh build\part_ps.h /Vn g_PSParticle src\particles.hlsl >nul || exit /b 1
fxc /nologo /T vs_4_0 /E VSLine /Fh build\line_vs.h /Vn g_VSLine src\particles.hlsl >nul || exit /b 1
fxc /nologo /T ps_4_0 /E PSLine /Fh build\line_ps.h /Vn g_PSLine src\particles.hlsl >nul || exit /b 1
fxc /nologo /T ps_4_0 /E PSBackground /Fh build\bg_ps.h /Vn g_PSBackground src\particles.hlsl >nul || exit /b 1

cl /nologo /O2 /MT /EHsc /std:c++20 /utf-8 /W3 /DUNICODE /D_UNICODE %VERDEF% /Ibuild src\*.cpp /Fobuild\ /Fe:LiteWallpaper.exe ^
   /link /SUBSYSTEM:WINDOWS /OPT:REF /OPT:ICF /MANIFEST:EMBED /MANIFESTINPUT:src\app.manifest ^
   user32.lib gdi32.lib shell32.lib ole32.lib oleaut32.lib advapi32.lib d3d11.lib dxgi.lib dwmapi.lib wtsapi32.lib ^
   windowscodecs.lib mfplat.lib mfuuid.lib comctl32.lib comdlg32.lib taskschd.lib uxtheme.lib winhttp.lib bcrypt.lib delayimp.lib ^
   /DELAYLOAD:mfplat.dll /DELAYLOAD:windowscodecs.dll /DELAYLOAD:wtsapi32.dll /DELAYLOAD:comdlg32.dll ^
   /DELAYLOAD:winhttp.dll /DELAYLOAD:bcrypt.dll || exit /b 1

echo Built LiteWallpaper.exe
