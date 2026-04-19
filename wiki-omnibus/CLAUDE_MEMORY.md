# OmniBus BlockChain - Work Memory

## Key Fixes Applied

### 1. Miner Manager Script (miner-manager.sh)
**Problem**: Script was STOPPING all existing miners before starting new ones. When adding miners in batches, each batch would replace the previous ones instead of adding to them.

**Fix**: Changed lines 41-61 to make miners add INCREMENTALLY:
- Track how many miners are currently running: `local running=$(get_running_count)`
- Start new miners after existing ones: `local start_id=$((10 + running))`
- Don't stop existing miners - just add more

**Result**: `bash add-miners-staggered.sh 100 10 5` now correctly adds 100 miners instead of replacing them.

### 2. Run Script (run.sh)
**Problem**: Only started extra miners, genesis miners (0-9) were never initialized.

**Fix**: Added genesis miner startup before extra miners (lines 89-101):
```bash
# Start Genesis Miners (0-9)
for i in $(seq 0 9); do
  node ./miner-client.js "miner-$i" "Miner-$i" "ob_omni_miner${i}xxx" 1000 > logs/miner-${i}.log 2>&1 &
  echo $! >> .miners_pids
  sleep 0.02
done
```

**Result**: System now properly starts 10 genesis miners + N extra miners.

### 3. Port Conflicts
**Problem**: Old RPC servers lingering on port 8332 cause new server startup to fail with EADDRINUSE.

**Aggressive Cleanup**:
```bash
ps aux | grep node | grep -v grep | awk '{print $2}' | xargs -r kill -9
```

## System Configuration
- **Genesis Miners**: miner-0 through miner-9 (stored in `.miners_pids`)
- **Extra Miners**: miner-10+ (stored in `.extra_miners_pids`)
- **Max Total**: 210 miners (10 genesis + 200 extra)
- **RPC Port**: 8332
- **Frontend Port**: 8888

## Quick Startup
```bash
bash run.sh 50          # Start with 50 extra miners (+ 10 genesis = 60 total)
bash add-miners-staggered.sh 100 10 5  # Add 100 miners in batches
bash run.sh status      # Check active miner count
bash run.sh stop        # Stop all
```
