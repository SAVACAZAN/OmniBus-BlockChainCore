#!/bin/bash

# OmniBus - Add Miners in Staggered Batches
# Adds N miners gradually to avoid system overload
# Usage: bash add-miners-staggered.sh 100 10 5
#        (add 100 miners, 10 per batch, 5 sec delay)

TOTAL_MINERS=${1:-100}
BATCH_SIZE=${2:-10}
BATCH_DELAY=${3:-5}

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     Adding $TOTAL_MINERS Miners in Staggered Batches         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Total:       $TOTAL_MINERS miners"
echo "  Batch Size:  $BATCH_SIZE miners/batch"
echo "  Delay:       $BATCH_DELAY seconds between batches"
echo ""

# Calculate batches
NUM_BATCHES=$(( (TOTAL_MINERS + BATCH_SIZE - 1) / BATCH_SIZE ))
echo -e "${YELLOW}Will add in $NUM_BATCHES batches${NC}"
echo ""

# Add miners in batches
ADDED=0
for batch in $(seq 1 $NUM_BATCHES); do
  REMAINING=$(( TOTAL_MINERS - ADDED ))
  TO_ADD=$(( REMAINING < BATCH_SIZE ? REMAINING : BATCH_SIZE ))

  echo -e "${GREEN}[Batch $batch/$NUM_BATCHES] Adding $TO_ADD miners...${NC}"
  bash miner-manager.sh start $TO_ADD > /dev/null 2>&1

  ADDED=$(( ADDED + TO_ADD ))
  PROGRESS=$(( ADDED * 100 / TOTAL_MINERS ))

  echo -e "  Progress: $ADDED/$TOTAL_MINERS ($PROGRESS%)"

  if [ $batch -lt $NUM_BATCHES ]; then
    echo -e "  ${YELLOW}Waiting $BATCH_DELAY seconds...${NC}"
    sleep $BATCH_DELAY
  fi

  echo ""
done

echo "╔════════════════════════════════════════════════════════════╗"
echo "✓ COMPLETE"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

echo -e "${GREEN}Added: $ADDED miners${NC}"
echo ""

echo -e "${YELLOW}Check status:${NC}"
echo "  ./run.sh status"
echo ""
