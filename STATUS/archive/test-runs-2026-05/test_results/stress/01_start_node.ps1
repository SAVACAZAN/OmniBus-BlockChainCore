# =============================================================================
# 01_start_node.ps1 - OmniBus Node launcher with auto-restart
# =============================================================================
# Purpose : Boot omnibus-node.exe in --regtest mode and supervise it. If the
#           node dies, restart it after 3 seconds. Each crash is appended to
#           crashes.log together with the last 50 lines of stderr.
# Usage   : pwsh -File 01_start_node.ps1
#           pwsh -File 01_start_node.ps1 -P2PPort 9700 -RpcPort 8332
# Output  : {date}/logs/node-<ts>.log     - stdout
#           {date}/logs/node-<ts>.err     - stderr
#           {date}/crashes.log            - crash chronicle (ISO 8601)
# Note    : ONLY --regtest is used to avoid touching mainnet DB.
# =============================================================================
[CmdletBinding()]
param(
    [int]$P2PPort = 9700,
    [int]$RpcPort = 8332,
    [int]$RestartDelaySec = 3,
    [string]$NodeId = "stress-regtest-1"
)

$ErrorActionPreference = 'Continue'
$script:RUN_DATE = (Get-Date -Format 'yyyy-MM-dd')
$script:STRESS_ROOT = Join-Path $PSScriptRoot $script:RUN_DATE
$script:LOG_DIR    = Join-Path $script:STRESS_ROOT 'logs'
$script:CRASH_LOG  = Join-Path $script:STRESS_ROOT 'crashes.log'
$script:PID_FILE   = Join-Path $script:STRESS_ROOT 'node.pid'
New-Item -ItemType Directory -Force -Path $script:LOG_DIR | Out-Null

# Resolve EXE relative to this script
$script:REPO_ROOT = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
$script:NODE_EXE  = Join-Path $script:REPO_ROOT 'zig-out\bin\omnibus-node.exe'

if (-not (Test-Path $script:NODE_EXE)) {
    Write-Error "omnibus-node.exe not found at $script:NODE_EXE - did you run 'zig build'?"
    exit 1
}

function Write-Crash {
    param([string]$Reason, [string]$ErrLog)
    $ts = (Get-Date).ToString('o')
    $tail = if (Test-Path $ErrLog) { Get-Content $ErrLog -Tail 50 -ErrorAction SilentlyContinue } else { @() }
    Add-Content -Path $script:CRASH_LOG -Value "===== CRASH $ts ====="
    Add-Content -Path $script:CRASH_LOG -Value "Reason : $Reason"
    Add-Content -Path $script:CRASH_LOG -Value "ErrLog : $ErrLog"
    Add-Content -Path $script:CRASH_LOG -Value "--- last 50 stderr lines ---"
    if ($tail.Count -gt 0) { Add-Content -Path $script:CRASH_LOG -Value $tail }
    Add-Content -Path $script:CRASH_LOG -Value ""
}

# Graceful Ctrl+C: kill child + flush logs
$script:KEEP_RUNNING = $true
$cancelHandler = {
    Write-Host "`n[01_start_node] Ctrl+C received - shutting down node ..." -ForegroundColor Yellow
    $script:KEEP_RUNNING = $false
    if ($script:CHILD_PROC -and -not $script:CHILD_PROC.HasExited) {
        try { $script:CHILD_PROC.Kill() } catch {}
    }
}
[Console]::TreatControlCAsInput = $false
Register-EngineEvent PowerShell.Exiting -Action $cancelHandler | Out-Null

Write-Host "[01_start_node] Supervising $script:NODE_EXE" -ForegroundColor Cyan
Write-Host "[01_start_node] Mode=regtest  P2P=$P2PPort  RPC=$RpcPort  NodeId=$NodeId"
Write-Host "[01_start_node] Logs in $script:LOG_DIR"
Write-Host "[01_start_node] Press Ctrl+C to stop supervision"

$attempt = 0
while ($script:KEEP_RUNNING) {
    $attempt++
    $ts     = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $stdout = Join-Path $script:LOG_DIR "node-$ts.log"
    $stderr = Join-Path $script:LOG_DIR "node-$ts.err"

    # Use 'seed' mode + --primary so node mines without needing peers
    $args = @(
        '--regtest',
        '--mode', 'seed',
        '--primary',
        '--node-id', $NodeId,
        '--port', $P2PPort.ToString()
    )

    Write-Host "[01_start_node] Attempt #$attempt - starting node ..." -ForegroundColor Green
    try {
        $script:CHILD_PROC = Start-Process -FilePath $script:NODE_EXE `
            -ArgumentList $args `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError  $stderr `
            -WorkingDirectory $script:REPO_ROOT `
            -PassThru -NoNewWindow

        $script:CHILD_PROC.Id | Out-File -FilePath $script:PID_FILE -Encoding ascii
        $script:CHILD_PROC.WaitForExit()
        $exitCode = $script:CHILD_PROC.ExitCode

        if (-not $script:KEEP_RUNNING) { break }

        Write-Host "[01_start_node] Node exited with code $exitCode" -ForegroundColor Red
        Write-Crash -Reason "exit_code=$exitCode" -ErrLog $stderr
    } catch {
        Write-Host "[01_start_node] Spawn error: $_" -ForegroundColor Red
        Write-Crash -Reason "spawn_error: $_" -ErrLog $stderr
    }

    if ($script:KEEP_RUNNING) {
        Write-Host "[01_start_node] Restart in $RestartDelaySec seconds ..." -ForegroundColor Yellow
        Start-Sleep -Seconds $RestartDelaySec
    }
}

Write-Host "[01_start_node] Supervisor stopped." -ForegroundColor Cyan
