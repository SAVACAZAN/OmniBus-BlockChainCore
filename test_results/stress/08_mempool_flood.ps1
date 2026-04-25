# =============================================================================
# 08_mempool_flood.ps1 - Mempool stress + observation
# =============================================================================
# Purpose : Try to inject TX-uri via sendrawtransaction. If the call is not
#           supported, fall back to rapid getmempoolinfo polls so we can still
#           record how the mempool grows/drains during the run.
# Usage   : pwsh -File 08_mempool_flood.ps1 -RateHz 20 -DurationSec 600
# Output  : {date}/mempool_<ts>.csv  - ts,size,bytes,inject_status
# =============================================================================
[CmdletBinding()]
param(
    [int]$RateHz = 20,
    [int]$DurationSec = 600,
    [int]$RpcPort = 8332,
    [string]$RpcHost = '127.0.0.1'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
$CSV = Join-Path $STRESS_ROOT "mempool_$ts.csv"
"ts,size,bytes,inject_status" | Out-File -FilePath $CSV -Encoding ascii

$rpcUrl = "http://${RpcHost}:${RpcPort}/"
$script:STOP = $false
$null = Register-EngineEvent -SourceIdentifier ConsoleCancelPressed -Action { $script:STOP = $true }

function Invoke-Rpc {
    param([string]$Method, [object]$Params = @())
    $body = @{ jsonrpc='2.0'; id=1; method=$Method; params=$Params } | ConvertTo-Json -Depth 6 -Compress
    return Invoke-RestMethod -Uri $rpcUrl -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop
}

$delayMs = [int](1000 / [math]::Max(1, $RateHz))
$start = Get-Date
$end = $start.AddSeconds($DurationSec)
$rng = New-Object System.Random
Write-Host "[08_mempool] Rate=${RateHz}Hz Duration=${DurationSec}s -> $rpcUrl" -ForegroundColor Cyan
$buf = New-Object System.Collections.Generic.List[string]
$polls = 0; $injects = 0

while ((Get-Date) -lt $end -and -not $script:STOP) {
    $injectStatus = 'skipped'
    # Inject one fake tx every 5th tick (to leave room for polls)
    if (($polls % 5) -eq 0) {
        $hex = -join ((1..64) | ForEach-Object { '{0:x}' -f $rng.Next(0,16) })
        $rawTx = "0x$hex"
        try {
            $r = Invoke-Rpc -Method 'sendrawtransaction' -Params @($rawTx)
            if ($r.error) { $injectStatus = "rpc_err:$($r.error.code)" } else { $injectStatus = 'sent'; $injects++ }
        } catch {
            $injectStatus = 'unsupported_or_err'
        }
    }

    $size = 'NA'; $bytes = 'NA'
    try {
        $r = Invoke-Rpc -Method 'getmempoolinfo'
        if ($r.result) {
            if ($null -ne $r.result.size)  { $size  = $r.result.size }
            if ($null -ne $r.result.bytes) { $bytes = $r.result.bytes }
        }
    } catch {}

    $buf.Add("$((Get-Date).ToString('o')),$size,$bytes,$injectStatus")
    if ($buf.Count -ge 50) { Add-Content -Path $CSV -Value $buf; $buf.Clear() }
    $polls++
    Start-Sleep -Milliseconds $delayMs
}

if ($buf.Count -gt 0) { Add-Content -Path $CSV -Value $buf }
Write-Host "[08_mempool] Done polls=$polls injects=$injects -> $CSV" -ForegroundColor Green
