@echo off
REM OmniBus Light Miner Launcher (Windows)
REM Launches multiple independent light miner instances

setlocal enabledelayedexpansion

echo.
echo ========================================
echo OmniBus Light Miner Launcher
echo ========================================
echo.

REM Check if omnibus-node executable exists
if not exist "omnibus-node.exe" (
    echo ERROR: omnibus-node.exe not found in current directory
    echo Please compile with: zig build-exe -O ReleaseFast core/main.zig --name omnibus-node
    echo.
    pause
    exit /b 1
)

REM Configuration
set SEED_HOST=127.0.0.1
set SEED_PORT=9000
set HASHRATE=1000

echo Launching 10 light miner instances...
echo Seed node: %SEED_HOST%:%SEED_PORT%
echo Hashrate per miner: %HASHRATE% H/s
echo.

REM Launch 10 miners
for /L %%i in (1,1,10) do (
    set MINER_ID=light-miner-%%i
    set NODE_ID=miner-%%i

    echo Starting !MINER_ID!...

    REM Launch miner in separate window
    start "!MINER_ID!" ^
        omnibus-node.exe ^
        --mode miner ^
        --node-id !NODE_ID! ^
        --seed-host %SEED_HOST% ^
        --seed-port %SEED_PORT% ^
        --hashrate %HASHRATE%

    REM Small delay between launches
    timeout /t 1 /nobreak
)

echo.
echo ========================================
echo All 10 miners launched!
echo ========================================
echo.
echo Miners will connect to: %SEED_HOST%:%SEED_PORT%
echo.
echo Open your browser to:
echo   http://localhost:3000/genesis-countdown
echo.
echo Closing this window...
echo (Miner windows will stay open)
timeout /t 5 /nobreak
