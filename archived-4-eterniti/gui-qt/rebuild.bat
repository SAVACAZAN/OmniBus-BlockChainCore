@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "C:\Kits work\limaje de programare\OmniBus-BlockChainCore\qt-gui\build"
cmake --build . 2>&1
echo BUILD_EXIT_CODE=%ERRORLEVEL%
