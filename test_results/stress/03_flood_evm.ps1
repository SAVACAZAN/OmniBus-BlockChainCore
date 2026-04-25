# =============================================================================
# 03_flood_evm.ps1 - EVM JSON-RPC stress
# =============================================================================
# Purpose : Hammer the EVM endpoints (eth_call, eth_chainId, eth_getCode,
#           eth_estimateGas, eth_blockNumber, eth_gasPrice).
# Usage   : pwsh -File 03_flood_evm.ps1 -CallsPerMethod 500
# Output  : {date}/evm_stress_<ts>.csv  - timestamp,method,latency_ms,status,result_size
# =============================================================================
[CmdletBinding()]
param(
    [int]$CallsPerMethod = 500,
    [int]$RpcPort = 8332,
    [string]$RpcHost = '127.0.0.1'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
$OUT_CSV = Join-Path $STRESS_ROOT "evm_stress_$ts.csv"
"timestamp,method,latency_ms,status,result_size" | Out-File -FilePath $OUT_CSV -Encoding ascii

$rpcUrl = "http://${RpcHost}:${RpcPort}/"
$ZERO = '0x0000000000000000000000000000000000000000'

$methods = @(
    @{ name = 'eth_chainId';      params = @() },
    @{ name = 'eth_blockNumber';  params = @() },
    @{ name = 'eth_gasPrice';     params = @() },
    @{ name = 'eth_getCode';      params = @($ZERO, 'latest') },
    @{ name = 'eth_call';         params = @(@{ to = $ZERO; data = '0x' }, 'latest') },
    @{ name = 'eth_estimateGas';  params = @(@{ to = $ZERO; data = '0x' }) }
)

$script:STOP = $false
$null = Register-EngineEvent -SourceIdentifier ConsoleCancelPressed -Action { $script:STOP = $true }

Write-Host "[03_flood_evm] $($methods.Count) methods x $CallsPerMethod calls -> $rpcUrl" -ForegroundColor Cyan
Write-Host "[03_flood_evm] CSV: $OUT_CSV"

$rowBuf = New-Object System.Collections.Generic.List[string]
$totalCalls = 0
$idCounter = 1

foreach ($m in $methods) {
    if ($script:STOP) { break }
    Write-Host "[03_flood_evm] -> $($m.name)" -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $CallsPerMethod; $i++) {
        if ($script:STOP) { break }
        $body = @{ jsonrpc='2.0'; id=$idCounter++; method=$m.name; params=$m.params } | ConvertTo-Json -Depth 6 -Compress
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 'ok'; $rsize = 0
        try {
            $resp = Invoke-RestMethod -Uri $rpcUrl -Method Post -Body $body `
                -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop
            if ($resp.error) {
                $status = "rpc_err:$($resp.error.code)"
            } elseif ($null -ne $resp.result) {
                $rsize = ($resp.result | Out-String).Trim().Length
            }
        } catch {
            $status = "http_err:$($_.Exception.Message -replace ',',';' -replace '\r?\n',' ')"
        }
        $sw.Stop()
        $rowBuf.Add("$((Get-Date).ToString('o')),$($m.name),$($sw.Elapsed.TotalMilliseconds),$status,$rsize")
        $totalCalls++
        if ($rowBuf.Count -ge 100) {
            Add-Content -Path $OUT_CSV -Value $rowBuf
            $rowBuf.Clear()
        }
    }
}

if ($rowBuf.Count -gt 0) { Add-Content -Path $OUT_CSV -Value $rowBuf }
Write-Host "[03_flood_evm] Done - $totalCalls calls in $OUT_CSV" -ForegroundColor Green
