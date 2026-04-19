@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

cd /d "%~dp0"

echo Building OmniBus WebView2 GUI...

cl.exe /EHsc /std:c++17 /O2 ^
  /DWEBVIEW_STATIC /DWEBVIEW_MSEDGE ^
  /I "C:\tmp\webview-src\webview-0.12.0\core\include" ^
  /I "C:\tmp\webview2\build\native\include" ^
  main.cpp ^
  /link ^
  "C:\tmp\webview_static.lib" ^
  "C:\tmp\webview2\build\native\x64\WebView2LoaderStatic.lib" ^
  advapi32.lib ole32.lib shell32.lib user32.lib version.lib crypt32.lib ^
  /SUBSYSTEM:WINDOWS ^
  /OUT:omnibus-webview.exe

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ══════════════════════════════════════
    echo   BUILD OK: omnibus-webview.exe
    echo ══════════════════════════════════════
) else (
    echo BUILD FAILED
)
