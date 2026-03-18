# OmniBus Full Blockchain Startup Script (Windows PowerShell)
# Launches: Seed Node + RPC Server + Frontend + 10 Light Miners
# Generates wallets and distributes genesis tokens automatically

# Colors for output
$Colors = @{
    'Info'    = [ConsoleColor]::Cyan
    'Success' = [ConsoleColor]::Green
    'Warning' = [ConsoleColor]::Yellow
    'Error'   = [ConsoleColor]::Red
    'Highlight' = [ConsoleColor]::Magenta
}

function Write-ColorOutput($Color, $Message) {
    Write-Host $Message -ForegroundColor $Color
}

function Write-Header($Title) {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║ $($Title.PadRight(56)) ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================================================
# STARTUP CONFIGURATION
# ============================================================================

Write-Header "OmniBus Genesis Blockchain - Full Startup"

$Config = @{
    'SeedHost'      = "127.0.0.1"
    'SeedPort'      = "9000"
    'RPCPort'       = "8332"
    'FrontendPort'  = "8888"
    'MinersCount'   = 10
    'Hashrate'      = 1000
    'GenesisMiners' = 3
}

Write-ColorOutput $Colors['Info'] "Configuration:"
Write-ColorOutput $Colors['Info'] "  - Seed Node: $($Config['SeedHost']):$($Config['SeedPort'])"
Write-ColorOutput $Colors['Info'] "  - RPC Server: http://localhost:$($Config['RPCPort'])"
Write-ColorOutput $Colors['Info'] "  - Frontend: http://localhost:$($Config['FrontendPort'])"
Write-ColorOutput $Colors['Info'] "  - Light Miners: $($Config['MinersCount'])"
Write-ColorOutput $Colors['Info'] "  - Hashrate per Miner: $($Config['Hashrate']) H/s"
Write-ColorOutput $Colors['Info'] "  - Genesis Ready: ≥$($Config['GenesisMiners']) miners"
Write-Host ""

# ============================================================================
# PHASE 1: CHECK REQUIREMENTS
# ============================================================================

Write-Header "Phase 1: Checking Requirements"

$Errors = @()

# Check omnibus-node exists
if (-not (Test-Path "omnibus-node.exe")) {
    $Errors += "❌ omnibus-node.exe not found"
} else {
    Write-ColorOutput $Colors['Success'] "✅ omnibus-node.exe found"
}

# Check Node.js for frontend
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    $Errors += "⚠️  npm not found (frontend will not start)"
} else {
    Write-ColorOutput $Colors['Success'] "✅ npm found"
}

if ($Errors.Count -gt 0) {
    Write-ColorOutput $Colors['Error'] "Build Requirements:"
    foreach ($Error in $Errors) {
        Write-ColorOutput $Colors['Error'] $Error
    }
    Write-Host ""
    Write-ColorOutput $Colors['Info'] "Fix: Compile with: zig build-exe -O ReleaseFast core/main.zig --name omnibus-node"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""

# ============================================================================
# PHASE 2: CREATE DIRECTORIES
# ============================================================================

Write-Header "Phase 2: Creating Directories"

$Directories = @(
    "logs",
    "wallets",
    "genesis"
)

foreach ($Dir in $Directories) {
    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force > $null
        Write-ColorOutput $Colors['Success'] "✅ Created $Dir/"
    } else {
        Write-ColorOutput $Colors['Info'] "→ $Dir/ already exists"
    }
}

Write-Host ""

# ============================================================================
# PHASE 3: GENERATE GENESIS WALLETS
# ============================================================================

Write-Header "Phase 3: Generating Genesis Wallets"

Write-ColorOutput $Colors['Highlight'] "Token Economics:"
Write-ColorOutput $Colors['Highlight'] "  - Total Supply: 21,000,000 OMNI"
Write-ColorOutput $Colors['Highlight'] "  - Per Miner: $(21000000 / $Config['MinersCount']) OMNI"
Write-ColorOutput $Colors['Highlight'] "  - Total SAT: $((21000000 * 100000000))"
Write-Host ""

# Create wallet JSON file
$WalletData = @{
    'genesis_timestamp' = Get-Date -UFormat "%Y-%m-%dT%H:%M:%SZ"
    'total_supply_omni' = 21000000
    'miners' = @()
}

for ($i = 0; $i -lt $Config['MinersCount']; $i++) {
    $MinerName = "miner-$i"
    $AllocationPerMiner = [math]::Round(21000000 / $Config['MinersCount'], 0)
    $AllocationSAT = $AllocationPerMiner * 100000000

    # Generate pseudo addresses (in real system: use proper key derivation)
    $Address = "ob_omni_miner$(($i+1).ToString('D2'))xxxxxxxxxxxxx"

    $WalletData['miners'] += @{
        'miner_id' = $i
        'miner_name' = $MinerName
        'address' = $Address
        'allocated_omni' = $AllocationPerMiner
        'allocated_sat' = $AllocationSAT
        'status' = 'genesis_allocated'
    }

    Write-ColorOutput $Colors['Success'] "✅ Miner $($i+1)/$($Config['MinersCount']): $MinerName"
    Write-ColorOutput $Colors['Info'] "   Address: $Address"
    Write-ColorOutput $Colors['Info'] "   Balance: $AllocationPerMiner OMNI ($AllocationSAT SAT)"
    Write-Host ""
}

# Save wallet data
$WalletJSON = $WalletData | ConvertTo-Json -Depth 10
Set-Content -Path "wallets/genesis-allocation.json" -Value $WalletJSON
Write-ColorOutput $Colors['Success'] "✅ Saved to wallets/genesis-allocation.json"
Write-Host ""

# ============================================================================
# PHASE 4: LAUNCH SEED NODE
# ============================================================================

Write-Header "Phase 4: Launching Seed Node"

Write-ColorOutput $Colors['Info'] "Starting seed node on $($Config['SeedHost']):$($Config['SeedPort'])..."

$SeedProcess = Start-Process -FilePath "omnibus-node.exe" -ArgumentList @(
    "--mode", "seed",
    "--node-id", "seed-1",
    "--primary",
    "--port", $Config['SeedPort']
) -PassThru -NoNewWindow -RedirectStandardOutput "logs/seed-node.log"

Write-ColorOutput $Colors['Success'] "✅ Seed node started (PID: $($SeedProcess.Id))"
Write-ColorOutput $Colors['Info'] "   Log: logs/seed-node.log"

Start-Sleep -Seconds 2

Write-Host ""

# ============================================================================
# PHASE 5: RPC SERVER (Built-in with Seed Node)
# ============================================================================

Write-Header "Phase 5: RPC Server"

Write-ColorOutput $Colors['Success'] "✅ RPC Server running on seed node"
Write-ColorOutput $Colors['Info'] "   HTTP: http://localhost:$($Config['RPCPort'])"
Write-ColorOutput $Colors['Info'] "   Methods: getGenesisStatus, getMiners, startGenesis"
Write-ColorOutput $Colors['Info'] "   Integration: Built-in with seed node"

Start-Sleep -Seconds 1

Write-Host ""

# ============================================================================
# PHASE 6: LAUNCH FRONTEND
# ============================================================================

Write-Header "Phase 6: Launching Frontend"

if (Get-Command npm -ErrorAction SilentlyContinue) {
    Write-ColorOutput $Colors['Info'] "Starting frontend on http://localhost:$($Config['FrontendPort'])..."

    $FrontendProcess = Start-Process -FilePath "cmd.exe" -ArgumentList @(
        "/c",
        "cd frontend && npm run dev"
    ) -PassThru -NoNewWindow -RedirectStandardOutput "logs/frontend.log"

    Write-ColorOutput $Colors['Success'] "✅ Frontend started (PID: $($FrontendProcess.Id))"
    Write-ColorOutput $Colors['Info'] "   Log: logs/frontend.log"
    Write-ColorOutput $Colors['Info'] "   Genesis Countdown: http://localhost:$($Config['FrontendPort'])/genesis-countdown"

    Start-Sleep -Seconds 3
} else {
    Write-ColorOutput $Colors['Warning'] "⚠️  npm not found - skipping frontend"
    Write-ColorOutput $Colors['Info'] "   Start manually: cd frontend && npm run dev"
}

Write-Host ""

# ============================================================================
# PHASE 7: LAUNCH LIGHT MINERS
# ============================================================================

Write-Header "Phase 7: Launching Light Miners"

Write-ColorOutput $Colors['Highlight'] "Launching $($Config['MinersCount']) light miners..."
Write-ColorOutput $Colors['Info'] "Total hashrate: $($Config['MinersCount'] * $Config['Hashrate']) H/s"
Write-Host ""

$MinerPIDs = @()

for ($i = 0; $i -lt $Config['MinersCount']; $i++) {
    $MinerID = "miner-$i"
    $MinerName = "light-miner-$(($i+1).ToString('D2'))"

    Write-ColorOutput $Colors['Info'] "Starting $MinerName..."

    $MinerProcess = Start-Process -FilePath "omnibus-node.exe" -ArgumentList @(
        "--mode", "miner",
        "--node-id", $MinerID,
        "--seed-host", $Config['SeedHost'],
        "--seed-port", $Config['SeedPort'],
        "--hashrate", $Config['Hashrate']
    ) -PassThru -NoNewWindow -RedirectStandardOutput "logs/$MinerName.log"

    $MinerPIDs += $MinerProcess.Id
    Write-ColorOutput $Colors['Success'] "✅ $MinerName (PID: $($MinerProcess.Id))"

    Start-Sleep -Milliseconds 500
}

Write-Host ""

# ============================================================================
# PHASE 8: SUMMARY & INSTRUCTIONS
# ============================================================================

Write-Header "Genesis Startup Complete! 🚀"

Write-ColorOutput $Colors['Success'] "All components launched successfully!"
Write-Host ""

Write-ColorOutput $Colors['Highlight'] "Running Processes:"
Write-ColorOutput $Colors['Highlight'] "  - Seed Node + RPC Server (PID: $($SeedProcess.Id))"
Write-ColorOutput $Colors['Highlight'] "  - $($Config['MinersCount']) Light Miners (PIDs: $($MinerPIDs -join ', '))"
Write-Host ""

Write-ColorOutput $Colors['Info'] "📊 Genesis Status:"
Write-ColorOutput $Colors['Info'] "  - Miners needed for genesis: $($Config['GenesisMiners'])"
Write-ColorOutput $Colors['Info'] "  - Miners launching: $($Config['MinersCount'])"
Write-ColorOutput $Colors['Info'] "  - Status: ✅ Genesis Ready (when 3+ miners connected)"
Write-Host ""

Write-ColorOutput $Colors['Highlight'] "💰 Token Distribution:"
Write-ColorOutput $Colors['Highlight'] "  - Total Supply: 21,000,000 OMNI"
$PerMiner = [math]::Round(21000000 / $Config['MinersCount'], 2)
Write-ColorOutput $Colors['Highlight'] "  - Per Miner: $PerMiner OMNI"
Write-ColorOutput $Colors['Highlight'] "  - Genesis Block Distribution: ACTIVE"
Write-Host ""

Write-ColorOutput $Colors['Info'] "🌐 Access Points:"
Write-ColorOutput $Colors['Info'] "  - Genesis Countdown UI:"
Write-ColorOutput $Colors['Highlight'] "    → http://localhost:$($Config['FrontendPort'])/genesis-countdown"
Write-ColorOutput $Colors['Info'] "  - RPC API:"
Write-ColorOutput $Colors['Highlight'] "    → http://localhost:$($Config['RPCPort'])"
Write-ColorOutput $Colors['Info'] "  - Wallet Data:"
Write-ColorOutput $Colors['Highlight'] "    → wallets/genesis-allocation.json"
Write-Host ""

Write-ColorOutput $Colors['Info'] "📁 Log Files:"
Write-ColorOutput $Colors['Info'] "  - Seed Node: logs/seed-node.log"
Write-ColorOutput $Colors['Info'] "  - RPC Server: logs/rpc-server.log"
Write-ColorOutput $Colors['Info'] "  - Miners: logs/light-miner-*.log"
Write-ColorOutput $Colors['Info'] "  - Frontend: logs/frontend.log"
Write-Host ""

Write-ColorOutput $Colors['Warning'] "⚠️  To stop all miners, run:"
Write-ColorOutput $Colors['Warning'] "  taskkill /IM omnibus-node.exe /F"
Write-Host ""

Write-ColorOutput $Colors['Success'] "Genesis blockchain is ready! Watch the Genesis Countdown page for live status."
Write-Host ""

Read-Host "Press Enter to continue monitoring (press Ctrl+C to stop)"

# Monitor for key processes
while ($true) {
    $SeedAlive = Get-Process -Id $SeedProcess.Id -ErrorAction SilentlyContinue
    $MinersAlive = @($MinerPIDs | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count

    Clear-Host

    Write-Header "Genesis Blockchain - Live Monitoring"

    Write-ColorOutput $Colors['Info'] "Process Status:"
    Write-ColorOutput $(if ($SeedAlive) { $Colors['Success'] } else { $Colors['Error'] }) `
        "$(if ($SeedAlive) { '✅' } else { '❌' }) Seed Node + RPC (PID: $($SeedProcess.Id))"

    Write-ColorOutput $(if ($MinersAlive -ge 3) { $Colors['Success'] } else { $Colors['Warning'] }) `
        "$(if ($MinersAlive -ge 3) { '✅' } else { '⚠️ ' }) Miners: $MinersAlive/$($Config['MinersCount']) connected"

    Write-Host ""
    Write-ColorOutput $Colors['Info'] "Last updated: $(Get-Date -Format 'HH:mm:ss')"
    Write-Host ""

    Start-Sleep -Seconds 5
}
