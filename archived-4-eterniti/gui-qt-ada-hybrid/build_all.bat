@echo off
echo ============================================================
echo   OmniBus Qt+Ada Hybrid Build
echo   Qt6 C++ GUI (MSVC) + Ada SPARK Vault (.dll)
echo ============================================================
echo.

:: ── Step 1: Ada SPARK DLL ────────────────────────────────────
echo [1/3] Building Ada SPARK vault library...
set GNAT_BIN=C:\Users\cazan\AppData\Local\alire\cache\toolchains\gnat_native_15.2.1_346e2e00\bin
set GPR_BIN=C:\Users\cazan\AppData\Local\alire\cache\toolchains\gprbuild_25.0.1_1bcdf5e8\bin
set PATH=%GNAT_BIN%;%GPR_BIN%;%PATH%

cd /d "%~dp0ada-vault"
if not exist obj mkdir obj
if not exist lib mkdir lib
gprbuild -P omnibus_vault.gpr -XMODE=release --target=x86_64-w64-mingw32 -j0
if errorlevel 1 (
    echo FAILED: Ada vault build
    exit /b 1
)
echo      OK: libomnibus_vault.dll

:: ── Step 2: MSVC + Qt6 ──────────────────────────────────────
echo.
echo [2/3] Building Qt6 GUI with MSVC...
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64

cd /d "%~dp0"
if not exist build mkdir build
cd build
cmake .. -G Ninja -DCMAKE_PREFIX_PATH=C:/Qt/6.8.3/msvc2022_64 -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
if errorlevel 1 (
    echo FAILED: CMake configure
    exit /b 1
)
cmake --build .
if errorlevel 1 (
    echo FAILED: Qt build
    exit /b 1
)

:: ── Step 3: Copy DLL ─────────────────────────────────────────
echo.
echo [3/3] Copying Ada vault DLL...
copy /Y "%~dp0ada-vault\lib\libomnibus_vault.dll" "%~dp0build\omnibus_vault.dll" >nul

echo.
echo ============================================================
echo   BUILD COMPLETE
echo   Ada SPARK: ada-vault\lib\libomnibus_vault.dll
echo   Qt6 GUI:   build\omnibus-qt-ada.exe
echo ============================================================
echo.
echo   Run: build\omnibus-qt-ada.exe
