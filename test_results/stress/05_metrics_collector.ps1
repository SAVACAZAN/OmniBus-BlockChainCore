# =============================================================================
# 05_metrics_collector.ps1 - Process & disk metrics every $IntervalSec
# =============================================================================
# Purpose : Snapshot RAM (WorkingSet64), CPU sec, HandleCount, Threads.Count,
#           and data/regtest/ disk usage. Writes one CSV row per tick.
# Usage   : pwsh -File 05_metrics_collector.ps1 -IntervalSec 10
# Output  : {date}/metrics.csv  - ts,pid,ram_mb,cpu_sec,handles,threads,disk_mb
# =============================================================================
[CmdletBinding()]
param(
    [int]$IntervalSec = 10,
    [string]$ProcessName = 'omnibus-node'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$OUT_CSV = Join-Path $STRESS_ROOT 'metrics.csv'
if (-not (Test-Path $OUT_CSV)) {
    "ts,pid,ram_mb,cpu_sec,handles,threads,disk_mb" | Out-File -FilePath $OUT_CSV -Encoding ascii
}

$REPO_ROOT  = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
$DATA_DIR   = Join-Path $REPO_ROOT 'data\regtest'

$script:STOP = $false
$null = Register-EngineEvent -SourceIdentifier ConsoleCancelPressed -Action { $script:STOP = $true }

Write-Host "[05_metrics] Tracking process '$ProcessName' every ${IntervalSec}s" -ForegroundColor Cyan
Write-Host "[05_metrics] CSV: $OUT_CSV"

while (-not $script:STOP) {
    $now = (Get-Date).ToString('o')
    $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    $diskMb = 0
    if (Test-Path $DATA_DIR) {
        try {
            $diskMb = [math]::Round(((Get-ChildItem -Path $DATA_DIR -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum / 1MB), 2)
        } catch {}
    }
    if ($procs) {
        foreach ($p in $procs) {
            $ramMb = [math]::Round($p.WorkingSet64 / 1MB, 2)
            $cpuSec = if ($null -ne $p.CPU) { [math]::Round($p.CPU, 3) } else { 0 }
            "$now,$($p.Id),$ramMb,$cpuSec,$($p.HandleCount),$($p.Threads.Count),$diskMb" | Add-Content -Path $OUT_CSV
        }
    } else {
        "$now,NA,0,0,0,0,$diskMb" | Add-Content -Path $OUT_CSV
    }
    Start-Sleep -Seconds $IntervalSec
}

Write-Host "[05_metrics] Stopped." -ForegroundColor Cyan
