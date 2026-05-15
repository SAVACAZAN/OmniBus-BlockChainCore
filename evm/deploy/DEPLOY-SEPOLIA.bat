@echo off
REM ── One-click deploy OmnibusDEX on Sepolia ─────────────────────────
REM Derives slot-6 privkey from your mnemonic at runtime, deploys,
REM and writes the address into evm/deployed_addresses.json.
REM
REM First run takes ~2 min (npm install). Subsequent runs ~30 sec.

cd /d "%~dp0"

echo.
echo ════════════════════════════════════════════════════════════════
echo  OmniBus DEX — Sepolia deploy
echo ════════════════════════════════════════════════════════════════
echo.

if not exist node_modules\ (
  echo [1/3] Installing dependencies (one-time, ~2 min)...
  call npm install
  if errorlevel 1 (
    echo npm install FAILED. Make sure Node.js + npm are installed.
    pause
    exit /b 1
  )
)

if not exist artifacts\ (
  echo [2/3] Compiling OmnibusDEX.sol...
  call npx hardhat compile
  if errorlevel 1 (
    echo Compile FAILED.
    pause
    exit /b 1
  )
)

echo [3/3] Deploying to Sepolia...
echo.
echo You will be asked for your OmniBus founder mnemonic (12 or 24 words).
echo The mnemonic stays in memory only — never written to disk.
echo.
call npx ts-node scripts/derive-and-deploy.ts --network sepolia

echo.
pause
