#!/usr/bin/env bash
# OmniBus Blockchain Core — Multi-Node Docker Launcher
# Launches 5 Docker containers: 1 seed + 4 miners on ports 9000-9004
# Uses the existing Dockerfile and docker-compose infrastructure.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_NAME="omnibus-net"
IMAGE_NAME="omnibus-node"
SEED_PORT=9000
RPC_PORT=8332
WS_PORT=8334
NUM_MINERS=4

# Mnemonics for deterministic wallets (test-only)
MNEMONICS=(
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
  "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong"
  "legal winner thank year wave sausage worth useful legal winner thank yellow"
  "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"
)

usage() {
  printf "${CYAN}Usage:${NC} %s [--build] [--down] [--logs] [--ps]\n" "$(basename "$0")"
  printf "  --build   Force rebuild Docker image before launching\n"
  printf "  --down    Stop and remove all OmniBus containers\n"
  printf "  --logs    Tail logs from all containers\n"
  printf "  --ps      Show running containers\n"
  printf "  (default) Build if needed, launch 1 seed + 4 miners\n"
  exit 0
}

do_build() {
  printf "${YELLOW}[BUILD]${NC} Building Docker image '%s' from %s...\n" "$IMAGE_NAME" "$PROJECT_ROOT"
  docker build -t "$IMAGE_NAME" "$PROJECT_ROOT"
  printf "${GREEN}[BUILD]${NC} Image built successfully.\n"
}

do_down() {
  printf "${YELLOW}[DOWN]${NC} Stopping all OmniBus containers...\n"
  for i in $(seq 1 $NUM_MINERS); do
    docker rm -f "omnibus-miner-$i" 2>/dev/null || true
  done
  docker rm -f "omnibus-seed" 2>/dev/null || true
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
  printf "${GREEN}[DOWN]${NC} All containers stopped.\n"
}

do_logs() {
  local containers=("omnibus-seed")
  for i in $(seq 1 $NUM_MINERS); do
    containers+=("omnibus-miner-$i")
  done
  docker logs -f --tail 50 "${containers[@]}" 2>&1
}

do_ps() {
  docker ps --filter "network=$NETWORK_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

do_launch() {
  # Check if Docker image exists, build if not
  if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    printf "${YELLOW}[INFO]${NC} Image '%s' not found, building...\n" "$IMAGE_NAME"
    do_build
  fi

  # Create network if it doesn't exist
  if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    printf "${YELLOW}[NET]${NC} Creating Docker network '%s'...\n" "$NETWORK_NAME"
    docker network create "$NETWORK_NAME"
  fi

  # Stop existing containers (clean slate)
  do_down 2>/dev/null || true
  docker network create "$NETWORK_NAME" 2>/dev/null || true

  # Launch seed node
  printf "${CYAN}[SEED]${NC} Launching seed node on P2P port %d, RPC port %d, WS port %d...\n" \
    "$SEED_PORT" "$RPC_PORT" "$WS_PORT"
  docker run -d \
    --name "omnibus-seed" \
    --network "$NETWORK_NAME" \
    -p "${SEED_PORT}:9000" \
    -p "${RPC_PORT}:8332" \
    -p "${WS_PORT}:8334" \
    -v "omnibus-seed-data:/omnibus/data" \
    "$IMAGE_NAME" \
    --mode seed --node-id seed-1 --primary --port 9000

  # Wait a moment for seed to start accepting connections
  printf "${YELLOW}[WAIT]${NC} Waiting 3s for seed node to initialize...\n"
  sleep 3

  # Launch miner nodes
  for i in $(seq 1 $NUM_MINERS); do
    local p2p_port=$((SEED_PORT + i))
    local mnemonic="${MNEMONICS[$((i - 1))]}"
    printf "${CYAN}[MINER-%d]${NC} Launching miner on P2P port %d...\n" "$i" "$p2p_port"
    docker run -d \
      --name "omnibus-miner-$i" \
      --network "$NETWORK_NAME" \
      -p "${p2p_port}:9000" \
      -e "OMNIBUS_MNEMONIC=${mnemonic}" \
      -v "omnibus-miner${i}-data:/omnibus/data" \
      "$IMAGE_NAME" \
      --mode miner --node-id "miner-$i" --seed-host omnibus-seed --seed-port 9000
  done

  printf "\n${GREEN}=== OmniBus Multi-Node Network Running ===${NC}\n\n"
  do_ps
  printf "\n${CYAN}Endpoints:${NC}\n"
  printf "  Seed RPC:      http://127.0.0.1:%d\n" "$RPC_PORT"
  printf "  Seed WebSocket: ws://127.0.0.1:%d\n" "$WS_PORT"
  printf "  Seed P2P:      127.0.0.1:%d\n" "$SEED_PORT"
  for i in $(seq 1 $NUM_MINERS); do
    printf "  Miner-%d P2P:   127.0.0.1:%d\n" "$i" "$((SEED_PORT + i))"
  done
  printf "\n${YELLOW}View logs:${NC} %s --logs\n" "$(basename "$0")"
  printf "${YELLOW}Stop all:${NC}  %s --down\n" "$(basename "$0")"
}

# --- Main ---
case "${1:-}" in
  --help|-h) usage ;;
  --build)   do_build; do_launch ;;
  --down)    do_down ;;
  --logs)    do_logs ;;
  --ps)      do_ps ;;
  *)         do_launch ;;
esac
