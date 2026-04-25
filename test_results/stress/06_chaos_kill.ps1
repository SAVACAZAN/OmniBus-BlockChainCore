# =============================================================================
# 06_chaos_kill.ps1 - Random kill chaos test
# =============================================================================
# Purpose : Every random interval (default 30..300 sec) kill the node process.
#           Counts on 01_start_node.ps1 to revive it. Writes a chronological
#           kill log so we can correlate with crashes.log + metrics.csv.
# Usage   : pwsh -File 06_chaos_kill.ps1 -MinSec 30 -MaxSec 300
# Output  : {date}/kills_<ts>.log
# =============================================================================
[CmdletBinding()]
param(
    [int]$MinSec = 30,
    [int]$MaxSec = 300,
    [string]$ProcessName = 'omnibus-node'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
$KILL_LOG = Join-Path $STRESS_ROOT "kills_$ts.log"

$script:STOP = $false
$null = Register-EngineEvent -SourceIdentifier ConsoleCancelPressed -Action { $script:STOP = $true }

$rng = New-Object System.Random
$count = 0
Write-Host "[06_chaos_kill] Killing '$ProcessName' every ${MinSec}..${MaxSec}s. Log=$KILL_LOG" -ForegroundColor Magenta

while (-not $script:STOP) {
    $sleep = $rng.Next($MinSec, $MaxSec + 1)
    Write-Host "[06_chaos_kill] Next kill in ${sleep}s ..." -ForegroundColor DarkMagenta
    $waited = 0
    while ($waited -lt $sleep -and -not $script:STOP) {
        Start-Sleep -Seconds 1
        $waited++
    }
    if ($script:STOP) { break }

    $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if (-not $procs) {
        $msg = "[$((Get-Date).ToString('o'))] no_target name=$ProcessName"
        Add-Content -Path $KILL_LOG -Value $msg
        Write-Host $msg -ForegroundColor Yellow
        continue
    }
    foreach ($p in $procs) {
        try {
            $p.Kill()
            $count++
            $msg = "[$((Get-Date).ToString('o'))] killed pid=$($p.Id) ram_mb=$([math]::Round($p.WorkingSet64/1MB,1)) #$count"
            Add-Content -Path $KILL_LOG -Value $msg
            Write-Host $msg -ForegroundColor Magenta
        } catch {
            Add-Content -Path $KILL_LOG -Value "[$((Get-Date).ToString('o'))] kill_err pid=$($p.Id) err=$_"
        }
    }
}

Add-Content -Path $KILL_LOG -Value "[$((Get-Date).ToString('o'))] STOP total_kills=$count"
Write-Host "[06_chaos_kill] Stopped. Total kills: $count" -ForegroundColor Cyan
