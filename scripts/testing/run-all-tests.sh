#!/usr/bin/env bash
# OmniBus Blockchain Core — Master Test Runner
# Runs all zig build test targets with timing, colors, and summary.

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TARGETS=(
  "test-crypto"
  "test-chain"
  "test-net"
  "test-storage"
  "test-pq"
  "test-light"
  "test-shard"
)

PASS=0
FAIL=0
START_TOTAL=$(date +%s)

printf "${YELLOW}=== OmniBus Master Test Runner ===${NC}\n\n"

for target in "${TARGETS[@]}"; do
  printf "${YELLOW}[RUN]${NC} zig build %s ...\n" "$target"
  T0=$(date +%s)
  if zig build "$target"; then
    T1=$(date +%s)
    ELAPSED=$((T1 - T0))
    printf "${GREEN}[PASS]${NC} %s (%ds)\n\n" "$target" "$ELAPSED"
    ((PASS++)) || true
  else
    T1=$(date +%s)
    ELAPSED=$((T1 - T0))
    printf "${RED}[FAIL]${NC} %s (%ds)\n\n" "$target" "$ELAPSED"
    ((FAIL++)) || true
  fi
done

END_TOTAL=$(date +%s)
TOTAL_ELAPSED=$((END_TOTAL - START_TOTAL))

printf "${YELLOW}========== SUMMARY ==========${NC}\n"
printf "Passed: ${GREEN}%d${NC}\n" "$PASS"
printf "Failed: ${RED}%d${NC}\n" "$FAIL"
printf "Total time: %ds\n" "$TOTAL_ELAPSED"

if [ "$FAIL" -ne 0 ]; then
  printf "${RED}Some tests failed.${NC}\n"
  exit 1
else
  printf "${GREEN}All tests passed.${NC}\n"
  exit 0
fi
