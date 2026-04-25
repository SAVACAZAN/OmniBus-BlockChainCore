# =============================================================================
# 09_evm_deploy_loop.ps1 - Deploy minimal contracts in a loop
# =============================================================================
# Purpose : Deploys a tiny EVM bytecode (PUSH1 0x42 PUSH1 0x00 MSTORE
#           PUSH1 0x20 PUSH1 0x00 RETURN) repeatedly. Records gas estimate +
#           returned address + status.
# Usage   : pwsh -File 09_evm_deploy_loop.ps1 -Count 100
# Output  : {date}/deploys_<ts>.log
#           {date}/deploys_<ts>.csv  - ts,iter,method,address,gas,status,latency_ms
# =============================================================================
[CmdletBinding()]
param(
    [int]$Count = 100,
    [int]$RpcPort = 8332,
    [string]$RpcHost = '127.0.0.1',
    [string]$From = '0x0000000000000000000000000000000000000001'
)

$ErrorActionPreference = 'Continue'
$RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$STRESS_ROOT = Join-Path $PSScriptRoot $RUN_DATE
New-Item -ItemType Directory -Force -Path $STRESS_ROOT | Out-Null
$ts = (Get-Date -Format 'yyyyMMdd-HHmmss')
$LOG = Join-Path $STRESS_ROOT "deploys_$ts.log"
$CSV = Join-Path $STRESS_ROOT "deploys_$ts.csv"
"ts,iter,method,address,gas,status,latency_ms" | Out-File -FilePath $CSV -Encoding ascii

$rpcUrl = "http://${RpcHost}:${RpcPort}/"

# Returns 32-byte word 0x42...
$BYTECODE = '0x6042600052602060006000f3'

function Invoke-Rpc {
    param([string]$Method, [object]$Params)
    $body = @{ jsonrpc='2.0'; id=1; method=$Method; params=$Params } | ConvertTo-Json -Depth 6 -Compress
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null; $errMsg = $null
    try {
        $resp = Invoke-RestMethod -Uri $rpcUrl -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop
    } catch { $errMsg = $_.Exception.Message }
    $sw.Stop()
    return [pscustomobject]@{ resp = $resp; err = $errMsg; ms = $sw.Elapsed.TotalMilliseconds }
}

$script:STOP = $false
$null = Register-EngineEvent -SourceIdentifier ConsoleCancelPressed -Action { $script:STOP = $true }

Write-Host "[09_evm_deploy] $Count deploy iterations -> $rpcUrl" -ForegroundColor Cyan
Add-Content -Path $LOG -Value "[$((Get-Date).ToString('o'))] START count=$Count rpc=$rpcUrl"

$success = 0; $failed = 0
for ($i = 0; $i -lt $Count; $i++) {
    if ($script:STOP) { break }
    $now = (Get-Date).ToString('o')

    # 1) eth_estimateGas for the deploy
    $gasParams = @(@{ from = $From; data = $BYTECODE })
    $g = Invoke-Rpc -Method 'eth_estimateGas' -Params $gasParams
    $gas = ''
    $gasStatus = 'ok'
    if ($g.err)            { $gasStatus = 'http_err'; $gas = '' }
    elseif ($g.resp.error) { $gasStatus = "rpc_err:$($g.resp.error.code)"; $gas = '' }
    else                   { $gas = $g.resp.result }
    "$now,$i,eth_estimateGas,,$gas,$gasStatus,$($g.ms)" | Add-Content -Path $CSV

    # 2) eth_sendTransaction (will fail if node has no signer, that is ok - we still log)
    $txParams = @(@{ from = $From; data = $BYTECODE; gas = '0x186A0' })
    $s = Invoke-Rpc -Method 'eth_sendTransaction' -Params $txParams
    $addr = ''
    $sStatus = 'ok'
    if ($s.err)            { $sStatus = 'http_err' }
    elseif ($s.resp.error) { $sStatus = "rpc_err:$($s.resp.error.code)" }
    else {
        $addr = $s.resp.result
        $success++
    }
    if ($sStatus -ne 'ok') { $failed++ }
    "$((Get-Date).ToString('o')),$i,eth_sendTransaction,$addr,,$sStatus,$($s.ms)" | Add-Content -Path $CSV

    if (($i % 10) -eq 0) {
        Write-Host "[09_evm_deploy] iter=$i ok=$success fail=$failed last_gas=$gas" -ForegroundColor DarkCyan
    }
}

Add-Content -Path $LOG -Value "[$((Get-Date).ToString('o'))] DONE ok=$success fail=$failed"
Write-Host "[09_evm_deploy] Done ok=$success fail=$failed -> $CSV" -ForegroundColor Green
