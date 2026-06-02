# =============================================================================
# 10_full_orchestrator.ps1 - Run everything in parallel for $DurationHours
# =============================================================================
# Purpose : Single entry-point that boots the supervisor + all stress workers
#           as background jobs, then shuts everything down at the end (or on
#           Ctrl+C). Generates the final report by invoking report.py.
# Usage   : pwsh -File 10_full_orchestrator.ps1 -DurationHours 24
#           pwsh -File 10_full_orchestrator.ps1 -DurationHours 0.5 -SkipChaos
# Output  : Each worker writes its own CSV/log under {date}/.
#           Final report: {date}/REPORT.md, {date}/REPORT.html
# Note    : ONLY --regtest. Never touches mainnet DB.
# =============================================================================
[CmdletBinding()]
param(
    [double]$DurationHours = 24,
    [int]$RpcPort = 8332,
    [int]$P2PPort = 9700,
    [switch]$SkipChaos,
    [switch]$SkipNode,            # Use this if you boot the node yourself
    [switch]$SkipReport
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$ORCH_LOG = Join-Path $STRESS_ROOT 'orchestrator.log'

function Log {
    param([string]$Msg, [ConsoleColor]$Color = 'White')
    $line = "[$((Get-Date).ToString('o'))] $Msg"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $ORCH_LOG -Value $line
}

$durationSec = [int]($DurationHours * 3600)
Log "=== Orchestrator START duration=${DurationHours}h (${durationSec}s) ===" Cyan
Log "Stress root: $STRESS_ROOT"
Log "RPC port=$RpcPort  P2P port=$P2PPort"

$script:STOP = $false
$null = Register-EngineEvent -SourceIdentifier ConsoleCancelPressed -Action {
    $script:STOP = $true
    Write-Host "`n[10_orchestrator] Ctrl+C received - tearing down jobs ..." -ForegroundColor Yellow
}

# Helper: launch a script as a background job, capturing its stdout to log
function Start-Worker {
    param([string]$Name, [string]$ScriptPath, [object[]]$Args)
    if (-not (Test-Path $ScriptPath)) {
        Log "MISSING $Name -> $ScriptPath" Red
        return $null
    }
    Log "Launch $Name $ScriptPath $($Args -join ' ')" Green
    # Try pwsh (PS7) first, fallback to powershell (Windows PowerShell)
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $job = Start-Job -Name $Name -ScriptBlock {
        param($shell, $p, $a)
        & $shell -NoProfile -ExecutionPolicy Bypass -File $p @a 2>&1
    } -ArgumentList $shell, $ScriptPath, $Args
    return $job
}

$jobs = @()

if (-not $SkipNode) {
    $jobs += Start-Worker -Name 'node' `
        -ScriptPath (Join-Path $PSScriptRoot '01_start_node.ps1') `
        -Args @('-P2PPort', $P2PPort, '-RpcPort', $RpcPort)
    Log "Waiting 10s for node warm-up ..."
    Start-Sleep -Seconds 10
}

$jobs += Start-Worker -Name 'block_monitor' `
    -ScriptPath (Join-Path $PSScriptRoot '04_block_monitor.ps1') `
    -Args @('-RpcPort', $RpcPort)

$jobs += Start-Worker -Name 'metrics' `
    -ScriptPath (Join-Path $PSScriptRoot '05_metrics_collector.ps1') `
    -Args @()

$jobs += Start-Worker -Name 'mempool' `
    -ScriptPath (Join-Path $PSScriptRoot '08_mempool_flood.ps1') `
    -Args @('-RpcPort', $RpcPort, '-DurationSec', $durationSec)

if (-not $SkipChaos) {
    $jobs += Start-Worker -Name 'chaos' `
        -ScriptPath (Join-Path $PSScriptRoot '06_chaos_kill.ps1') `
        -Args @()
}

# Periodic flood + concurrent + evm deploy waves while we wait
$end = (Get-Date).AddSeconds($durationSec)
$wave = 0
while ((Get-Date) -lt $end -and -not $script:STOP) {
    $wave++
    Log "Wave #$wave starting (rpc flood + evm flood + concurrent + deploys)" DarkCyan
    $waveJobs = @()
    $waveJobs += Start-Worker -Name "rpc_flood_$wave"  -ScriptPath (Join-Path $PSScriptRoot '02_flood_rpc.ps1') `
        -Args @('-Threads', 10, '-CallsPerThread', 200, '-RpcPort', $RpcPort)
    $waveJobs += Start-Worker -Name "evm_flood_$wave"  -ScriptPath (Join-Path $PSScriptRoot '03_flood_evm.ps1') `
        -Args @('-CallsPerMethod', 200, '-RpcPort', $RpcPort)
    $waveJobs += Start-Worker -Name "concurrent_$wave" -ScriptPath (Join-Path $PSScriptRoot '07_concurrent_clients.ps1') `
        -Args @('-Clients', 20, '-CallsEach', 50, '-RpcPort', $RpcPort)
    $waveJobs += Start-Worker -Name "deploy_$wave"     -ScriptPath (Join-Path $PSScriptRoot '09_evm_deploy_loop.ps1') `
        -Args @('-Count', 50, '-RpcPort', $RpcPort)

    foreach ($j in $waveJobs) {
        if ($null -eq $j) { continue }
        while ($j.State -eq 'Running' -and (Get-Date) -lt $end -and -not $script:STOP) {
            Start-Sleep -Seconds 3
        }
        try { Receive-Job -Job $j -Keep | Out-File -Append (Join-Path $STRESS_ROOT "$($j.Name).out") } catch {}
        Stop-Job -Job $j -ErrorAction SilentlyContinue
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
    if (-not $script:STOP -and (Get-Date) -lt $end) {
        $cool = [Math]::Min(30, [int](($end - (Get-Date)).TotalSeconds))
        if ($cool -gt 0) {
            Log "Wave #$wave done. Cooldown ${cool}s." DarkGray
            Start-Sleep -Seconds $cool
        }
    }
}

Log "=== Tearing down long-running jobs ===" Yellow
foreach ($j in $jobs) {
    if ($null -eq $j) { continue }
    try {
        Stop-Job -Job $j -ErrorAction SilentlyContinue
        $tail = Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue
        if ($tail) { $tail | Out-File -Append (Join-Path $STRESS_ROOT "$($j.Name).out") }
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    } catch {}
}

# Best-effort: kill any leftover node we started
if (-not $SkipNode) {
    Get-Process -Name omnibus-node -ErrorAction SilentlyContinue | ForEach-Object {
        Log "Stopping leftover omnibus-node pid=$($_.Id)" Yellow
        try { $_.Kill() } catch {}
    }
}

# Archive logs into a tarball-friendly folder name (already date-stamped)
Log "Archive folder: $STRESS_ROOT"

if (-not $SkipReport) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    $reportPy = Join-Path $PSScriptRoot 'report.py'
    if ($py -and (Test-Path $reportPy)) {
        Log "Generating REPORT.md / REPORT.html via $($py.Source)" Cyan
        & $py.Source $reportPy --date $RUN_DATE
    } else {
        Log "Python or report.py missing - skipping report" Yellow
    }
}

Log "=== Orchestrator DONE ===" Cyan
