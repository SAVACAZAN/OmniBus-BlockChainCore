#!/bin/bash
# VPS health monitoring — Phase 7
RESULTS="/c/Kits work/limaje de programare/1_CORE/BlockChainCore/stress-results"
CSV="$RESULTS/vps-health.csv"
echo "ts,uptime_load1,load5,load15,mem_total,mem_used,mem_free,mem_avail,procs" > "$CSV"
DURATION_MIN=${1:-60}
END=$(($(date +%s) + DURATION_MIN*60))
while [ $(date +%s) -lt $END ]; do
  TS=$(date -Iseconds)
  OUT=$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=no omnibus-vps "uptime; free -m | head -2 | tail -1; ps aux | grep omnibus-node | grep -v grep | wc -l" 2>/dev/null)
  if [ -n "$OUT" ]; then
    LOAD=$(echo "$OUT" | head -1 | awk -F'load average:' '{print $2}' | tr -d ' ' | tr ',' ' ')
    MEM=$(echo "$OUT" | sed -n '2p' | awk '{print $2","$3","$4","$7}')
    PROCS=$(echo "$OUT" | tail -1)
    echo "$TS,$LOAD,$MEM,$PROCS" >> "$CSV"
  else
    echo "$TS,SSH_FAIL,,,,,,," >> "$CSV"
  fi
  sleep 60
done
