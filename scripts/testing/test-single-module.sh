#!/usr/bin/env bash
# OmniBus Blockchain Core — Single Module Test Runner
# Usage: ./test-single-module.sh <module_name>
# Example: ./test-single-module.sh secp256k1

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

MODULE="${1:-}"
if [ -z "$MODULE" ]; then
  printf "${RED}Usage:${NC} %s <module_name>\n" "$0"
  printf "Available modules in core/:\n"
  ls -1 core/*.zig | sed 's|core/||;s|.zig||' | column
  exit 1
fi

FILE="core/${MODULE}.zig"
if [ ! -f "$FILE" ]; then
  printf "${RED}Error:${NC} module file not found: %s\n" "$FILE"
  exit 1
fi

printf "${YELLOW}[RUN]${NC} zig test %s\n" "$FILE"
T0=$(date +%s)

if zig test "$FILE"; then
  T1=$(date +%s)
  ELAPSED=$((T1 - T0))
  printf "${GREEN}[PASS]${NC} %s (%ds)\n" "$MODULE" "$ELAPSED"
  exit 0
else
  T1=$(date +%s)
  ELAPSED=$((T1 - T0))
  printf "${RED}[FAIL]${NC} %s (%ds)\n" "$MODULE" "$ELAPSED"
  exit 1
fi
