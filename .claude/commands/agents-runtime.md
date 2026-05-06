# /agents-runtime

Manage the always-on agent runtime that schedules + monitors the 16
Claude Code subagents working on the OmniBus ecosystem.

The runtime lives outside this repo:
```
C:\Kits work\limaje de programare\10_Toolz\DevSecSuite\agents-runtime\
```

## What it does

- **Scheduler** (APScheduler) fires auditor agents on a cron cadence:
  - `inventory-scanner` every 30 min
  - `blockchain-security-auditor` daily 04:00
  - `blockchain-test-runner` every 6h
  - `blockchain-performance-tuner` Mondays 05:00
  - `blockchain-consensus-expert` Mondays 06:00
  - `Blockchain-Git-Learner` Mondays 07:00
  - `Blockchain-Exploit-Lab` Sundays 03:00
- **Monitor** (watchdog) picks up reports written under `STATUS/` and
  feeds them through `learner.py` which extracts findings into
  `data/learnings/<agent>.md`. Those learnings get auto-attached as
  context the next time the agent runs.
- **Bus** (file queue) lets agents publish jobs for each other, e.g.
  `blockchain-test-runner` publishes `build-broken` and
  `omnibus-blockchain-fixer` claims it.

## Common ops

```powershell
# Snapshot of all agents (rich TUI)
python C:\Kits work\limaje de programare\10_Toolz\DevSecSuite\agents-runtime\dashboard.py

# Live watch (refresh 10s)
python C:\Kits work\limaje de programare\10_Toolz\DevSecSuite\agents-runtime\dashboard.py --watch

# Run one agent ad-hoc
python C:\Kits work\limaje de programare\10_Toolz\DevSecSuite\agents-runtime\core\runner.py blockchain-test-runner

# Start daemons (scheduler + monitor in two minimised consoles)
C:\Kits work\limaje de programare\10_Toolz\DevSecSuite\agents-runtime\launch-all.bat

# Install as Windows scheduled task (auto-start on logon)
powershell -ExecutionPolicy Bypass -File C:\Kits work\limaje de programare\10_Toolz\DevSecSuite\agents-runtime\install-windows-task.ps1

# See what's scheduled without firing anything
python C:\Kits work\limaje de programare\10_Toolz\DevSecSuite\agents-runtime\core\scheduler.py --dry-run
```

## When invoked, Claude should

1. Print the dashboard snapshot (`python dashboard.py`).
2. Show the user any agents whose last run had `exit != 0`.
3. If the user asks to "run X" — invoke
   `python core/runner.py <agent-id>` and show the result.
4. If the user asks "what did X find" — read
   `data/learnings/<agent>.md` and surface the latest section.

## Files of interest

- `agents.yaml` — registry; edit to add agents or change cadence.
- `data/runs/<agent>.jsonl` — append-only run history.
- `data/learnings/<agent>.md` — distilled per-agent memory.
- `logs/scheduler.log` — daemon log (cron firings).
- `logs/monitor.log` — daemon log (file events).
