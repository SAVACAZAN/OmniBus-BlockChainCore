@echo off
REM run-stress.bat — Double-click runner for the 30-min multi-wallet stress test (testnet)
setlocal

echo.
echo === OmniBus Multi-Wallet Stress (testnet, ~30 min) ===
echo.

where node >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: node not found in PATH.
    echo Install Node.js 20+ and retry.
    pause
    exit /b 1
)

node "%~dp0test-scripts/30-multiwallet-full-stress.mjs" --chain testnet %*

echo.
echo === Done — exit code %ERRORLEVEL% ===
pause
endlocal
