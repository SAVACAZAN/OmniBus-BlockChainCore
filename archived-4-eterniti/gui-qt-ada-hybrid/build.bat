@echo off
echo ============================================================
echo   OmniBus Qt+Ada Hybrid Build
echo   Qt6 C++ GUI + Ada SPARK Vault (.dll)
echo ============================================================
echo.

set GNAT_BIN=C:\Users\cazan\AppData\Local\alire\cache\toolchains\gnat_native_15.2.1_346e2e00\bin
set GPR_BIN=C:\Users\cazan\AppData\Local\alire\cache\toolchains\gprbuild_25.0.1_1bcdf5e8\bin
set PATH=%GNAT_BIN%;%GPR_BIN%;%PATH%

echo [1/3] Building Ada SPARK vault library...
cd /d "%~dp0ada-vault"
if not exist obj mkdir obj
if not exist lib mkdir lib
gprbuild -P omnibus_vault.gpr -XMODE=release --target=x86_64-w64-mingw32 -j0
if errorlevel 1 (
    echo FAILED: Ada vault build
    exit /b 1
)
echo      OK: omnibus_vault.dll built

echo.
echo [2/3] Building Qt6 C++ GUI...
cd /d "%~dp0"
if not exist build mkdir build
cd build
cmake .. -G Ninja
if errorlevel 1 (
    echo FAILED: CMake configure
    exit /b 1
)
cmake --build . --config Release
if errorlevel 1 (
    echo FAILED: Qt build
    exit /b 1
)
echo      OK: omnibus-qt-ada.exe built

echo.
echo [3/3] Done!
echo   Ada SPARK vault: ada-vault\lib\libomnibus_vault.dll
echo   Qt6 GUI:         build\omnibus-qt-ada.exe
echo.
echo   Run: build\omnibus-qt-ada.exe
