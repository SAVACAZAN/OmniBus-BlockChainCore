# =============================================================================
# 02_flood_rpc.ps1 - JSON-RPC stress (concurrent calls)
# =============================================================================
# Purpose : Saturate the RPC port with concurrent calls. Rotates through a
#           list of read-only methods (getblockcount, getbalance,
#           getblockchaininfo, eth_chainId).
# Usage   : pwsh -File 02_flood_rpc.ps1 -Threads 10 -CallsPerThread 1000
# Output  : {date}/rpc_stress_<ts>.csv  - timestamp,thread,method,latency_ms,status
# Note    : Uses background jobs; Ctrl+C kills jobs and flushes the CSV.
# =============================================================================
[CmdletBinding()]
param(
    [int]$Threads = 10,
    [int]$CallsPerThread = 1000,
    [int]$RpcPort = 8332,
    [string]$RpcHost = '127.0.0.1'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
$OUT_CSV = Join-Path $STRESS_ROOT "rpc_stress_$ts.csv"

"timestamp,thread,method,latency_ms,status" | Out-File -FilePath $OUT_CSV -Encoding ascii

$worker = {
    param($threadId, $calls, $rpcUrl, $outCsv)
    $methods = @('getblockcount','getbalance','getblockchaininfo','eth_chainId')
    $rng = New-Object System.Random ($threadId * 7919)
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $calls; $i++) {
        $method = $methods[$rng.Next(0, $methods.Length)]
        $body = @{ jsonrpc='2.0'; id=$i; method=$method; params=@() } | ConvertTo-Json -Compress
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'ok'
        try {
            $resp = Invoke-RestMethod -Uri $rpcUrl -Method Post -Body $body `
                -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop
            if ($resp.error) { $status = "rpc_err:$($resp.error.code)" }
        } catch {
            $status = "http_err:$($_.Exception.Message -replace ',',';' -replace '\r?\n',' ')"
        }
        $sw.Stop()
        $lines.Add("$((Get-Date).ToString('o')),$threadId,$method,$($sw.Elapsed.TotalMilliseconds),$status")
        if ($lines.Count -ge 100) {
            Add-Content -Path $outCsv -Value $lines
            $lines.Clear()
        }
    }
    if ($lines.Count -gt 0) { Add-Content -Path $outCsv -Value $lines }
    return "thread $threadId done ($calls calls)"
}

$rpcUrl = "http://${RpcHost}:${RpcPort}/"
Write-Host "[02_flood_rpc] $Threads threads x $CallsPerThread calls -> $rpcUrl" -ForegroundColor Cyan
Write-Host "[02_flood_rpc] CSV: $OUT_CSV"

$jobs = @()
for ($t = 0; $t -lt $Threads; $t++) {
    $jobs += Start-Job -ScriptBlock $worker -ArgumentList $t, $CallsPerThread, $rpcUrl, $OUT_CSV
}

try {
    while ($jobs | Where-Object { $_.State -eq 'Running' }) {
        Start-Sleep -Seconds 2
        $running = ($jobs | Where-Object { $_.State -eq 'Running' }).Count
        Write-Host "[02_flood_rpc] $running/$Threads threads still running ..." -ForegroundColor DarkGray
    }
} finally {
    foreach ($j in $jobs) {
        try { Receive-Job -Job $j | Out-Null } catch {}
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
}

$total = (Get-Content $OUT_CSV).Count - 1
Write-Host "[02_flood_rpc] Done - $total rows in $OUT_CSV" -ForegroundColor Green
