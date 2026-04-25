# =============================================================================
# 04_block_monitor.ps1 - Monitor block production rate
# =============================================================================
# Purpose : Poll getblockcount every $IntervalSec seconds. Compute blocks/min
#           and blocks/hour. Detect stalls (no height delta for >StallSec).
# Usage   : pwsh -File 04_block_monitor.ps1 -IntervalSec 2 -StallSec 60
# Output  : {date}/block_height.csv  - timestamp,height,delta,blocks_per_min,stalled
#           {date}/block_stalls.log
# =============================================================================
[CmdletBinding()]
param(
    [int]$IntervalSec = 2,
    [int]$StallSec    = 60,
    [int]$RpcPort     = 8332,
    [string]$RpcHost  = '127.0.0.1'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$OUT_CSV   = Join-Path $STRESS_ROOT 'block_height.csv'
$STALL_LOG = Join-Path $STRESS_ROOT 'block_stalls.log'
if (-not (Test-Path $OUT_CSV)) {
    "timestamp,height,delta,blocks_per_min,stalled" | Out-File -FilePath $OUT_CSV -Encoding ascii
}

$rpcUrl = "http://${RpcHost}:${RpcPort}/"
$script:STOP = $false
$null = Register-EngineEvent -SourceIdentifier ConsoleCancelPressed -Action { $script:STOP = $true }

Write-Host "[04_block_monitor] Polling $rpcUrl every ${IntervalSec}s; stall threshold ${StallSec}s" -ForegroundColor Cyan

$lastHeight     = -1
$lastChangeTime = Get-Date
$samples        = New-Object System.Collections.Generic.Queue[psobject]
$stallReported  = $false

while (-not $script:STOP) {
    $now = Get-Date
    $body = '{"jsonrpc":"2.0","id":1,"method":"getblockcount","params":[]}'
    $height = $null
    try {
        $resp = Invoke-RestMethod -Uri $rpcUrl -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop
        if ($null -ne $resp.result) { $height = [int64]$resp.result }
    } catch {
        # leave $height as $null - we still log the gap
    }

    $delta   = 0
    $stalled = 0
    if ($null -ne $height) {
        if ($lastHeight -lt 0) {
            $lastHeight = $height
            $lastChangeTime = $now
        } else {
            $delta = $height - $lastHeight
            if ($delta -gt 0) {
                $lastHeight = $height
                $lastChangeTime = $now
                $stallReported = $false
            } else {
                $idle = ($now - $lastChangeTime).TotalSeconds
                if ($idle -ge $StallSec) {
                    $stalled = 1
                    if (-not $stallReported) {
                        $msg = "[$($now.ToString('o'))] STALL height=$height idle_for=${idle}s"
                        Add-Content -Path $STALL_LOG -Value $msg
                        Write-Host $msg -ForegroundColor Red
                        $stallReported = $true
                    }
                }
            }
        }
        # Sliding window: keep last 60 seconds for blocks/min
        $samples.Enqueue([pscustomobject]@{ t = $now; h = $height })
        while ($samples.Count -gt 0 -and ($now - $samples.Peek().t).TotalSeconds -gt 60) {
            $samples.Dequeue() | Out-Null
        }
        $bpm = 0
        if ($samples.Count -ge 2) {
            $first = $samples.Peek()
            $bpm = $height - $first.h
        }
        $heightStr = $height
    } else {
        $heightStr = 'NA'
        $bpm = 0
    }

    "$($now.ToString('o')),$heightStr,$delta,$bpm,$stalled" | Add-Content -Path $OUT_CSV
    Write-Host "[04_block_monitor] h=$heightStr delta=$delta bpm=$bpm stalled=$stalled" -ForegroundColor DarkGray
    Start-Sleep -Seconds $IntervalSec
}

Write-Host "[04_block_monitor] Stopped." -ForegroundColor Cyan
