# OmniBus Stress Test Suite

10 PowerShell scripts + 1 Python report generator for stress-testing
`omnibus-node.exe` in **regtest** mode. Mainnet is never touched.

## Layout

```
test_results/stress/
  01_start_node.ps1         supervisor with auto-restart
  02_flood_rpc.ps1          concurrent RPC flood
  03_flood_evm.ps1          EVM endpoint flood
  04_block_monitor.ps1      block height + stall detection
  05_metrics_collector.ps1  RAM / CPU / handles / disk
  06_chaos_kill.ps1         random kills (chaos)
  07_concurrent_clients.ps1 20 parallel jobs
  08_mempool_flood.ps1      sendrawtransaction / getmempoolinfo
  09_evm_deploy_loop.ps1    minimal contract deploy loop
  10_full_orchestrator.ps1  runs everything for N hours
  report.py                 aggregates CSVs into REPORT.md / REPORT.html
  README.md                 this file
  <YYYY-MM-DD>/             per-run output folder (auto-created)
    logs/                   stdout/stderr from the supervisor
    crashes.log             one entry per restart with last 50 stderr lines
    block_height.csv
    block_stalls.log
    metrics.csv
    rpc_stress_*.csv
    evm_stress_*.csv
    concurrent_*.csv
    mempool_*.csv
    deploys_*.csv
    kills_*.log
    orchestrator.log
    REPORT.md / REPORT.html (after report.py)
```

## Prerequisites

- `zig build` already produced `zig-out/bin/omnibus-node.exe` and the matching
  UCRT/MinGW DLLs in the same folder.
- PowerShell 7 (`pwsh`) recommended. Windows PowerShell 5.1 also works for the
  individual scripts (the orchestrator launches each child via `pwsh`).
- Python 3.10+ on PATH (only needed for `report.py`).

## One-shot run (recommended)

```powershell
cd "C:\Kits work\limaje de programare\1_CORE\BlockChainCore\test_results\stress"
pwsh -File .\10_full_orchestrator.ps1 -DurationHours 24
```

That single command:

1. Boots `omnibus-node.exe --regtest` under the auto-restart supervisor.
2. Starts the long-running watchers (block monitor, metrics, mempool, chaos).
3. Repeatedly fires waves of RPC flood + EVM flood + concurrent clients +
   contract deploys until the duration elapses.
4. Tears every job down on `Ctrl+C` or after the timer.
5. Generates `<date>/REPORT.md` and `<date>/REPORT.html`.

Useful flags:

```powershell
-DurationHours 0.5    # quick smoke test (~30 min)
-SkipChaos            # disable random kills
-SkipNode             # if you want to start the node yourself
-SkipReport           # skip Python report
-RpcPort 8332 -P2PPort 9700
```

## Running scripts individually

Each script also runs standalone. Examples:

```powershell
pwsh -File .\01_start_node.ps1                                 # just the supervisor
pwsh -File .\02_flood_rpc.ps1 -Threads 20 -CallsPerThread 500
pwsh -File .\03_flood_evm.ps1 -CallsPerMethod 2000
pwsh -File .\04_block_monitor.ps1 -IntervalSec 2 -StallSec 60
pwsh -File .\05_metrics_collector.ps1 -IntervalSec 5
pwsh -File .\06_chaos_kill.ps1 -MinSec 60 -MaxSec 600
pwsh -File .\07_concurrent_clients.ps1 -Clients 50 -CallsEach 200
pwsh -File .\08_mempool_flood.ps1 -RateHz 30 -DurationSec 1800
pwsh -File .\09_evm_deploy_loop.ps1 -Count 500
```

All of them honour `Ctrl+C` and finish writing their CSV before exiting.

## Auto-restart pattern

`01_start_node.ps1` is a forever-loop that:

1. Spawns the EXE with `Start-Process -PassThru` and redirected stdout/stderr.
2. Calls `WaitForExit()`.
3. On any non-clean exit, appends to `crashes.log` (timestamp + reason +
   last 50 stderr lines) and sleeps `-RestartDelaySec` (default 3 s).
4. Exits cleanly when `Ctrl+C` flips `$KEEP_RUNNING = $false`.

`06_chaos_kill.ps1` works in tandem: it picks a random delay between
`-MinSec` and `-MaxSec`, then `Get-Process omnibus-node | Kill()`. The
supervisor immediately restarts. Compare `kills_*.log` against `crashes.log`
to see whether every kill produced a clean recovery.

## Graceful shutdown pattern

Every script:

- Sets `$ErrorActionPreference = 'Continue'`.
- Declares `$script:STOP = $false`.
- Registers `ConsoleCancelPressed` (or, in `01_start_node.ps1`, the engine's
  exit event) to flip `$STOP = $true`.
- Buffers CSV rows in a small `List[string]` and flushes either every 50 rows
  or at exit, so a `Ctrl+C` never leaves a half-written line.
- The orchestrator additionally calls `Stop-Job` / `Remove-Job` on every
  background job before exiting.

## Reading the report

After a run finishes (or whenever you want a snapshot):

```powershell
python .\report.py --date 2026-04-25
```

The report includes:

- Crash count vs chaos-kill count with recovery rate.
- RPC / EVM / concurrent latency table per method (avg / p95 / p99 / max).
- Block production rate (blocks/min, blocks/hour) + stall detection.
- Memory growth verdict (`OK` / `WATCH` / `LIKELY LEAK`) over the run.
- Mempool size statistics + injection breakdown.
- EVM deploy success/failure breakdown.

## Disk-budget estimate (24 h run)

Rough numbers for a default 24 h orchestrator run (RPC port 8332, regtest):

| Source | Rate | Per 24 h |
|---|---|---|
| `metrics.csv` (10 s tick) | ~80 B/row | ~0.7 MB |
| `block_height.csv` (2 s tick) | ~70 B/row | ~3 MB |
| `mempool_*.csv` (20 Hz) | ~70 B/row | ~115 MB |
| `rpc_stress_*.csv` (waves) | ~110 B/row | ~50-150 MB |
| `evm_stress_*.csv` (waves) | ~120 B/row | ~30-80 MB |
| `concurrent_*.csv` (waves) | ~100 B/row | ~20-60 MB |
| `deploys_*.csv` | small | ~1 MB |
| node stdout/stderr | log-volume dependent | 50-500 MB |

Plan for **~0.5-1 GB** under `<date>/`. Mostly plain CSV/text, gzip-friendly.
