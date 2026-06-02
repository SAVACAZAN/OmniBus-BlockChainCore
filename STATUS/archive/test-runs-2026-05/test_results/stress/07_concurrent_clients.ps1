# =============================================================================
# 07_concurrent_clients.ps1 - Many parallel clients
# =============================================================================
# Purpose : Spawn 20 background jobs. Each fires 100 random RPC calls. Goal is
#           to surface race conditions / deadlocks under wide concurrency.
# Usage   : pwsh -File 07_concurrent_clients.ps1 -Clients 20 -CallsEach 100
# Output  : {date}/concurrent_<ts>.log  - one line per client summary
#           {date}/concurrent_<ts>.csv  - per-call detail
# =============================================================================
[CmdletBinding()]
param(
    [int]$Clients = 20,
    [int]$CallsEach = 100,
    [int]$RpcPort = 8332,
    [string]$RpcHost = '127.0.0.1'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
$LOG = Join-Path $STRESS_ROOT "concurrent_$ts.log"
$CSV = Join-Path $STRESS_ROOT "concurrent_$ts.csv"
"timestamp,client,method,latency_ms,status" | Out-File -FilePath $CSV -Encoding ascii

$rpcUrl = "http://${RpcHost}:${RpcPort}/"
Write-Host "[07_concurrent] $Clients clients x $CallsEach calls -> $rpcUrl" -ForegroundColor Cyan

$worker = {
    param($cid, $calls, $url, $csv)
    $methods = @('getblockcount','getblockchaininfo','getbalance','eth_chainId','eth_blockNumber','eth_gasPrice')
    $rng = New-Object System.Random ($cid * 31337)
    $ok = 0; $err = 0
    $buf = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $calls; $i++) {
        $m = $methods[$rng.Next(0, $methods.Length)]
        $body = @{ jsonrpc='2.0'; id=$i; method=$m; params=@() } | ConvertTo-Json -Compress
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $st = 'ok'
        try {
            $r = Invoke-RestMethod -Uri $url -Method Post -Body $body `
                -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop
            if ($r.error) { $st = "rpc_err:$($r.error.code)"; $err++ } else { $ok++ }
        } catch {
            $st = "http_err"; $err++
        }
        $sw.Stop()
        $buf.Add("$((Get-Date).ToString('o')),$cid,$m,$($sw.Elapsed.TotalMilliseconds),$st")
        if ($buf.Count -ge 50) { Add-Content -Path $csv -Value $buf; $buf.Clear() }
    }
    if ($buf.Count -gt 0) { Add-Content -Path $csv -Value $buf }
    return "client=$cid ok=$ok err=$err"
}

$jobs = @()
for ($c = 0; $c -lt $Clients; $c++) {
    $jobs += Start-Job -ScriptBlock $worker -ArgumentList $c, $CallsEach, $rpcUrl, $CSV
}

try {
    while ($jobs | Where-Object { $_.State -eq 'Running' }) {
        Start-Sleep -Seconds 2
        $running = ($jobs | Where-Object { $_.State -eq 'Running' }).Count
        Write-Host "[07_concurrent] $running/$Clients still running ..." -ForegroundColor DarkGray
    }
} finally {
    foreach ($j in $jobs) {
        $summary = $null
        try { $summary = Receive-Job -Job $j -ErrorAction SilentlyContinue } catch {}
        if ($summary) { Add-Content -Path $LOG -Value $summary }
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[07_concurrent] Done - summary in $LOG, CSV in $CSV" -ForegroundColor Green
