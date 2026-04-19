#!/usr/bin/env bash
# OmniBus Blockchain Core — Hot Path Profiler
# Identifies bottlenecks using perf (Linux), valgrind (Linux), or zig built-in profiler.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

BINARY="zig-out/bin/omnibus-node"
BENCH_BINARY="zig-out/bin/omnibus-bench"

printf "${YELLOW}=== OmniBus Hot Path Profiler ===${NC}\n\n"

# Ensure binaries exist
if [ ! -f "$BINARY" ]; then
  printf "${YELLOW}[BUILD]${NC} Building omnibus-node...\n"
  zig build || { printf "${RED}Build failed${NC}\n"; exit 1; }
fi

if [ ! -f "$BENCH_BINARY" ]; then
  printf "${YELLOW}[BUILD]${NC} Building omnibus-bench...\n"
  zig build bench || true
fi

# Detect available profiler
HAS_PERF=0
HAS_VALGRIND=0
HAS_ZIG_PROF=0

if command -v perf &> /dev/null; then
  HAS_PERF=1
fi
if command -v valgrind &> /dev/null; then
  HAS_VALGRIND=1
fi
if zig build --help 2>/dev/null | grep -q "prof"; then
  HAS_ZIG_PROF=1
fi

printf "${YELLOW}[INFO]${NC} perf=%d valgrind=%d zig_prof=%d\n\n" "$HAS_PERF" "$HAS_VALGRIND" "$HAS_ZIG_PROF"

# Run perf if available
if [ "$HAS_PERF" -eq 1 ]; then
  printf "${YELLOW}[RUN]${NC} perf record -g on %s ...\n" "$BENCH_BINARY"
  perf record -g -- "$BENCH_BINARY" || true
  printf "${YELLOW}[REPORT]${NC} Top hot paths (perf report --stdio head -n 20):\n"
  perf report --stdio | head -n 30 || true
  printf "\n"
fi

# Run valgrind/callgrind if available
if [ "$HAS_VALGRIND" -eq 1 ]; then
  printf "${YELLOW}[RUN]${NC} valgrind --tool=callgrind %s ...\n" "$BENCH_BINARY"
  valgrind --tool=callgrind --callgrind-out-file=callgrind.out.omnibus "$BENCH_BINARY" || true
  if command -v callgrind_annotate &> /dev/null; then
    printf "${YELLOW}[REPORT]${NC} callgrind_annotate top functions:\n"
    callgrind_annotate callgrind.out.omnibus | head -n 30 || true
  fi
  printf "\n"
fi

# Zig built-in profiler placeholder (uses -femit-docs or trace)
printf "${YELLOW}[TIP]${NC} For Zig built-in profiling, build with:\n"
printf "  zig build -Doptimize=ReleaseSafe -finstrument-functions\n"
printf "  # Then analyze with uftrace or similar.\n"

printf "${GREEN}=== Profiling complete ===${NC}\n"
