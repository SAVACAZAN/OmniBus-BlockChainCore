#!/usr/bin/env bash
# start-all-vps.sh — porneste 3 noduri (mainnet/testnet/regtest) + Vite explorer
# in background, cu logs si PID file. Idempotent: oprire & repornire curate.
#
# Usage:
#   ./start-all-vps.sh start    # porneste tot
#   ./start-all-vps.sh stop     # opreste tot
#   ./start-all-vps.sh restart  # opreste si reporneste
#   ./start-all-vps.sh status   # ce ruleaza?
#   ./start-all-vps.sh logs     # tail -f la log-ul ales
set -euo pipefail

ROOT="/root/omnibus-blockchain"
NODE="$ROOT/zig-out/bin/omnibus-node"
LOG_DIR="/var/log/omnibus"
PID_DIR="/run/omnibus"
mkdir -p "$LOG_DIR" "$PID_DIR"

# Porturi RPC/WS sunt hardcoded in chain_config.zig (per chain), deci NU se ciocnesc.
# P2P port il dam noi cu --port.
declare -A P2P_PORTS=(
  [mainnet]=9000
  [testnet]=9001
  [regtest]=9002
)

start_node() {
  local chain="$1"
  local p2p_port="${P2P_PORTS[$chain]}"
  local pidfile="$PID_DIR/$chain.pid"
  local logfile="$LOG_DIR/$chain.log"

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "[$chain] deja ruleaza (PID $(cat "$pidfile"))"
    return 0
  fi

  echo "[$chain] pornire pe P2P port $p2p_port ..."
  nohup "$NODE" \
    --mode seed \
    --chain "$chain" \
    --node-id "vps-$chain" \
    --host 0.0.0.0 \
    --port "$p2p_port" \
    > "$logfile" 2>&1 &
  echo $! > "$pidfile"
  disown
  sleep 1
  if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "[$chain] OK PID=$(cat "$pidfile") log=$logfile"
  else
    echo "[$chain] FAIL — vezi $logfile"
  fi
}

start_explorer() {
  local pidfile="$PID_DIR/explorer.pid"
  local logfile="$LOG_DIR/explorer.log"
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "[explorer] deja ruleaza (PID $(cat "$pidfile"))"
    return 0
  fi
  echo "[explorer] pornire Vite pe :8888 ..."
  cd "$ROOT/frontend"
  nohup npm run dev -- --host 0.0.0.0 > "$logfile" 2>&1 &
  echo $! > "$pidfile"
  disown
  cd - > /dev/null
  sleep 2
  if kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "[explorer] OK PID=$(cat "$pidfile") log=$logfile"
  else
    echo "[explorer] FAIL — vezi $logfile"
  fi
}

stop_one() {
  local name="$1"
  local pidfile="$PID_DIR/$name.pid"
  if [[ ! -f "$pidfile" ]]; then
    echo "[$name] nu ruleaza"
    return 0
  fi
  local pid
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      echo "[$name] forteaza kill -9 PID=$pid"
      kill -9 "$pid" || true
    fi
    echo "[$name] oprit (era PID=$pid)"
  else
    echo "[$name] PID stale, deja terminat"
  fi
  rm -f "$pidfile"
}

cmd_start() {
  for c in mainnet testnet regtest; do
    start_node "$c"
  done
  start_explorer
  echo ""
  cmd_status
}

cmd_stop() {
  for c in explorer mainnet testnet regtest; do
    stop_one "$c"
  done
  # safety: kill orphans
  pkill -f 'omnibus-node' 2>/dev/null || true
  pkill -f 'vite' 2>/dev/null || true
}

cmd_status() {
  echo "=== Status servicii OmniBus ==="
  for c in mainnet testnet regtest explorer; do
    local pidfile="$PID_DIR/$c.pid"
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      printf "  %-10s UP    PID=%s\n" "$c" "$(cat "$pidfile")"
    else
      printf "  %-10s DOWN\n" "$c"
    fi
  done
  echo ""
  echo "=== Porturi LISTEN ==="
  ss -tlnp 2>/dev/null | grep -E ':(8332|8334|8888|9000|18332|18334|9001|28332|28334|9002)\b' || echo "  nimic in listen"
  echo ""
  echo "=== URLs ==="
  echo "  Explorer    : http://38.143.19.97:8888"
  echo "  RPC mainnet : http://38.143.19.97:8332"
  echo "  RPC testnet : http://38.143.19.97:18332"
  echo "  RPC regtest : http://38.143.19.97:28332"
  echo "  Logs in     : $LOG_DIR/{mainnet,testnet,regtest,explorer}.log"
}

cmd_logs() {
  local which="${1:-explorer}"
  local logfile="$LOG_DIR/$which.log"
  if [[ ! -f "$logfile" ]]; then
    echo "Log inexistent: $logfile"
    echo "Disponibile: $(ls $LOG_DIR/ 2>/dev/null | tr '\n' ' ')"
    exit 1
  fi
  echo "=== tail -f $logfile (Ctrl+C ca sa iesi, NU opreste serviciul) ==="
  tail -f "$logfile"
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; sleep 1; cmd_start ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "${1:-explorer}" ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs [chain]}"
    echo "  chain = mainnet|testnet|regtest|explorer (default: explorer)"
    exit 1
    ;;
esac
