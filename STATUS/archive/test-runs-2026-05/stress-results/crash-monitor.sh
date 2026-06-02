#!/bin/bash
# Crash hunt — Phase 8
RESULTS="/c/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results"
LOG="$RESULTS/crash-events.log"
echo "=== Crash hunt start $(date -Iseconds) ===" > "$LOG"
DURATION_MIN=${1:-60}
END=$(($(date +%s) + DURATION_MIN*60))
declare -A SEEN
while [ $(date +%s) -lt $END ]; do
  TS=$(date -Iseconds)
  CRASH=$(ssh -o ConnectTimeout=10 omnibus-vps "grep -aE 'panic|SEGV|ABRT|fatal|reached unreachable|Segmentation|signal' /var/log/omnibus/mainnet.log /var/log/omnibus/testnet.log 2>/dev/null | tail -50" 2>/dev/null)
  if [ -n "$CRASH" ]; then
    HASH=$(echo "$CRASH" | md5sum | awk '{print $1}')
    if [ -z "${SEEN[$HASH]}" ]; then
      SEEN[$HASH]=1
      echo "--- $TS NEW PATTERN ---" >> "$LOG"
      echo "$CRASH" >> "$LOG"
    fi
  fi
  sleep 300
done
echo "=== END $(date -Iseconds) ===" >> "$LOG"
