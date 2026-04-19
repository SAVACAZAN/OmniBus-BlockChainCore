#!/usr/bin/env bash
# OmniBus Blockchain Core — Chain Data Backup with Rotation
# Backs up omnibus-chain.dat with timestamp, keeps last 10 backups.
# Creates backups/ directory if it doesn't exist.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHAIN_FILE="${PROJECT_ROOT}/omnibus-chain.dat"
BACKUP_DIR="${PROJECT_ROOT}/backups"
RETENTION=10

printf "${CYAN}=== OmniBus Chain Data Backup ===${NC}\n"
printf "${DIM}Chain file: %s${NC}\n" "$CHAIN_FILE"
printf "${DIM}Backup dir: %s${NC}\n" "$BACKUP_DIR"
printf "${DIM}Retention:  %d backups${NC}\n\n" "$RETENTION"

# Verify chain file exists
if [ ! -f "$CHAIN_FILE" ]; then
  printf "${RED}[ERROR]${NC} Chain file not found: %s\n" "$CHAIN_FILE"
  printf "${YELLOW}[HINT]${NC} Run the node first to create omnibus-chain.dat\n"
  exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Generate timestamped backup name
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILE_SIZE=$(stat -c%s "$CHAIN_FILE" 2>/dev/null || stat -f%z "$CHAIN_FILE" 2>/dev/null || echo "unknown")
BACKUP_NAME="omnibus-chain_${TIMESTAMP}.dat"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Copy chain data
printf "${YELLOW}[COPY]${NC} %s -> %s (%s bytes)\n" \
  "$(basename "$CHAIN_FILE")" "$BACKUP_NAME" "$FILE_SIZE"
cp "$CHAIN_FILE" "$BACKUP_PATH"

# Compress with gzip if available
if command -v gzip &>/dev/null; then
  printf "${YELLOW}[GZIP]${NC} Compressing backup...\n"
  gzip -f "$BACKUP_PATH"
  BACKUP_PATH="${BACKUP_PATH}.gz"
  COMPRESSED_SIZE=$(stat -c%s "$BACKUP_PATH" 2>/dev/null || stat -f%z "$BACKUP_PATH" 2>/dev/null || echo "?")
  printf "${DIM}       %s bytes -> %s bytes${NC}\n" "$FILE_SIZE" "$COMPRESSED_SIZE"
else
  printf "${DIM}[INFO] gzip not available, backup uncompressed${NC}\n"
fi

# Rotate: keep only the last $RETENTION backups (sorted by name = by timestamp)
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/omnibus-chain_*.dat* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$RETENTION" ]; then
  REMOVE_COUNT=$((BACKUP_COUNT - RETENTION))
  printf "${YELLOW}[ROTATE]${NC} Removing %d old backup(s) (keeping newest %d)...\n" \
    "$REMOVE_COUNT" "$RETENTION"
  ls -1t "$BACKUP_DIR"/omnibus-chain_*.dat* | tail -n +"$((RETENTION + 1))" | while read -r old; do
    printf "${DIM}  rm %s${NC}\n" "$(basename "$old")"
    rm -f "$old"
  done
fi

# Summary
printf "\n${GREEN}[DONE]${NC} Backup complete.\n"
printf "${CYAN}Current backups:${NC}\n"
ls -lh "$BACKUP_DIR"/omnibus-chain_*.dat* 2>/dev/null | while read -r line; do
  printf "  %s\n" "$line"
done

FINAL_COUNT=$(ls -1 "$BACKUP_DIR"/omnibus-chain_*.dat* 2>/dev/null | wc -l)
printf "\n${DIM}Total backups: %d / %d max${NC}\n" "$FINAL_COUNT" "$RETENTION"
