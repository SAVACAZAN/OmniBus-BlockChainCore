@echo off
REM run-tests.bat — Double-click runner for OmniBus blockchain test suite (testnet)
REM Detects WSL or Git Bash and forwards to test-scripts/run-all.sh
setlocal

echo.
echo === OmniBus Test Suite (testnet) ===
echo.

REM 1) Try Git Bash (most common Windows dev setup)
where bash >nul 2>nul
if %ERRORLEVEL%==0 (
    echo Using bash from PATH...
    bash "%~dp0test-scripts/run-all.sh" --chain testnet %*
    goto :end
)

REM 2) Try WSL
where wsl >nul 2>nul
if %ERRORLEVEL%==0 (
    echo Using WSL...
    wsl bash test-scripts/run-all.sh --chain testnet %*
    goto :end
)

REM 3) Fallback: explicit Git Bash path
if exist "C:\Program Files\Git\bin\bash.exe" (
    echo Using C:\Program Files\Git\bin\bash.exe ...
    "C:\Program Files\Git\bin\bash.exe" "%~dp0test-scripts/run-all.sh" --chain testnet %*
    goto :end
)

echo ERROR: no bash found. Install Git for Windows or enable WSL.
pause
exit /b 1

:end
echo.
echo === Done — exit code %ERRORLEVEL% ===
pause
endlocal
