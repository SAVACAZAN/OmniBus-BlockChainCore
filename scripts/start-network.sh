#!/bin/bash
# start-network.sh — Start OmniBus seed node + 10 miners (staggered 60s apart)
# Each miner gets a unique mnemonic saved to wallets/
# Mining starts only when 10 miners are connected

set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
NODE="$ROOT/zig-out/bin/omnibus-node.exe"
WALLETS_DIR="$ROOT/wallets"
LOGS_DIR="$ROOT/data/logs"

mkdir -p "$WALLETS_DIR" "$LOGS_DIR"

# ── BIP-39 word list (first 128 words for real mnemonic generation) ──────────
# Full BIP-39: 2048 words. We use crypto randomBytes + this subset.
# The node derives addresses from mnemonic via HMAC-SHA512 (bip32_wallet.zig)

MINER_COUNT=10
SEED_PORT=9000
RPC_PORT=8332
STAGGER_SECONDS=60

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           OmniBus Network — 10 Miner Startup                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Seed node:    port $SEED_PORT (RPC $RPC_PORT, WS 8334)"
echo "  Miners:       $MINER_COUNT (staggered ${STAGGER_SECONDS}s apart)"
echo "  Wallets:      $WALLETS_DIR/"
echo ""

# ── Kill existing instances ──────────────────────────────────────────────────
echo "[CLEANUP] Stopping existing nodes..."
taskkill //F //IM omnibus-node.exe 2>/dev/null || true
sleep 2

# ── Reset blockchain ─────────────────────────────────────────────────────────
echo "[RESET] Deleting old chain data..."
rm -f "$ROOT/omnibus-chain.dat"

# ── Generate 10 unique mnemonics ─────────────────────────────────────────────
# Using node.js crypto for proper random generation
echo "[WALLETS] Generating $MINER_COUNT unique wallets..."

node -e "
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// BIP-39 English wordlist (first 256 words — enough for 12-word mnemonics from entropy)
const words = [
  'abandon','ability','able','about','above','absent','absorb','abstract',
  'absurd','abuse','access','accident','account','accuse','achieve','acid',
  'acoustic','acquire','across','act','action','actor','actress','actual',
  'adapt','add','addict','address','adjust','admit','adult','advance',
  'advice','aerobic','affair','afford','afraid','again','age','agent',
  'agree','ahead','aim','air','airport','aisle','alarm','album',
  'alcohol','alert','alien','all','alley','allow','almost','alone',
  'alpha','already','also','alter','always','amateur','amazing','among',
  'amount','amused','analyst','anchor','ancient','anger','angle','angry',
  'animal','ankle','announce','annual','another','answer','antenna','antique',
  'anxiety','any','apart','apology','appear','apple','approve','april',
  'arch','arctic','area','arena','argue','arm','armed','armor',
  'army','around','arrange','arrest','arrive','arrow','art','artefact',
  'artist','artwork','ask','aspect','assault','asset','assist','assume',
  'asthma','athlete','atom','attack','attend','attitude','attract','auction',
  'audit','august','aunt','author','auto','autumn','average','avocado',
  'avoid','awake','aware','awesome','awful','awkward','axis','baby',
  'bachelor','bacon','badge','bag','balance','balcony','ball','bamboo',
  'banana','banner','bar','barely','bargain','barrel','base','basic',
  'basket','battle','beach','bean','beauty','because','become','beef',
  'before','begin','behave','behind','believe','below','belt','bench',
  'benefit','best','betray','better','between','beyond','bicycle','bid',
  'bike','bind','biology','bird','birth','bitter','black','blade',
  'blame','blanket','blast','bleak','bless','blind','blood','blossom',
  'blow','blue','blur','blush','board','boat','body','boil',
  'bomb','bone','bonus','book','boost','border','boring','borrow',
  'boss','bottom','bounce','box','boy','bracket','brain','brand',
  'brass','brave','bread','breeze','brick','bridge','brief','bright',
  'bring','brisk','broccoli','broken','bronze','broom','brother','brown'
];

const miners = [];
for (let i = 0; i < $MINER_COUNT; i++) {
  // Generate 12-word mnemonic from 16 bytes entropy
  const entropy = crypto.randomBytes(16);
  const mnemonic = [];
  for (let j = 0; j < 12; j++) {
    const idx = ((entropy[j % 16] * 256 + entropy[(j + 1) % 16]) + j * 17) % words.length;
    mnemonic.push(words[idx]);
  }
  const phrase = mnemonic.join(' ');

  // Derive address (same as vault_reader → bip32_wallet in Zig)
  const seed = crypto.pbkdf2Sync(phrase, 'TREZOR', 2048, 64, 'sha512');
  const key = crypto.createHmac('sha256', seed).update('0').digest();
  const hash = crypto.createHash('sha256').update(key).digest('hex');
  const addr = 'ob_omni_' + hash.substring(0, 32);

  miners.push({
    id: 'miner-' + i,
    mnemonic: phrase,
    address: addr,
    port: ${SEED_PORT} + 100 + i
  });
}

// Save
const walletsDir = path.resolve(__dirname, '..', 'wallets');
if (!fs.existsSync(walletsDir)) fs.mkdirSync(walletsDir, {recursive: true});
fs.writeFileSync(path.join(walletsDir, 'network_miners.json'), JSON.stringify(miners, null, 2));

// Print summary
miners.forEach((m, i) => {
  console.log('  Miner ' + i + ': ' + m.address.substring(0, 28) + '... | ' + m.mnemonic.split(' ').slice(0, 3).join(' ') + '...');
});
console.log('');
console.log('  Saved to: wallets/network_miners.json');
" 2>&1

echo ""

# ── Start seed node ──────────────────────────────────────────────────────────
echo "[SEED] Starting seed node on port $SEED_PORT..."
OMNIBUS_MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about" \
  "$NODE" --mode seed --node-id seed-1 --port $SEED_PORT > "$LOGS_DIR/seed.log" 2>&1 &
SEED_PID=$!
echo "  PID: $SEED_PID"
sleep 5

# Verify seed is running
if curl -s -X POST http://localhost:$RPC_PORT -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getstatus","params":[],"id":1}' | grep -q "running"; then
  echo "  [OK] Seed node running, RPC on :$RPC_PORT"
else
  echo "  [FAIL] Seed node not responding!"
  exit 1
fi

echo ""

# ── Start miners one by one, 60 seconds apart ───────────────────────────────
echo "[MINERS] Starting $MINER_COUNT miners (${STAGGER_SECONDS}s stagger)..."
echo ""

for i in $(seq 0 $(($MINER_COUNT - 1))); do
  MINER_ID="miner-$i"
  MINER_PORT=$((SEED_PORT + 100 + i))

  # Read mnemonic from saved file
  MNEMONIC=$(node -e "
    const path = require('path');
    const m = require(path.resolve(__dirname || '.', '..', 'wallets', 'network_miners.json'));
    console.log(m[$i].mnemonic);
  " 2>/dev/null || node -e "
    const m = require('$(cygpath -w "$WALLETS_DIR/network_miners.json" 2>/dev/null || echo "$WALLETS_DIR/network_miners.json")');
    console.log(m[$i].mnemonic);
  " 2>/dev/null || echo "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")

  echo "  [$((i+1))/$MINER_COUNT] Starting $MINER_ID on port $MINER_PORT..."
  echo "          Mnemonic: $(echo $MNEMONIC | cut -d' ' -f1-3)..."

  OMNIBUS_MNEMONIC="$MNEMONIC" \
    "$NODE" --mode miner --node-id "$MINER_ID" \
    --seed-host 127.0.0.1 --seed-port $SEED_PORT \
    --port $MINER_PORT > "$LOGS_DIR/$MINER_ID.log" 2>&1 &

  echo "          PID: $!"

  # Register miner with seed node via RPC
  sleep 2
  curl -s -X POST http://localhost:$RPC_PORT -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"registerminer\",\"params\":[\"$MINER_ID\"],\"id\":$((i+100))}" > /dev/null 2>&1

  PEERS=$(curl -s -X POST http://localhost:$RPC_PORT -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"getstatus","params":[],"id":99}' 2>/dev/null | \
    node -e "process.stdin.on('data',d=>{try{const r=JSON.parse(d);console.log(r.result?.blockCount||'?')}catch{console.log('?')}})" 2>/dev/null || echo "?")

  echo "          Registered. Chain height: $PEERS"
  echo ""

  # Wait before next miner (except last one)
  if [ $i -lt $(($MINER_COUNT - 1)) ]; then
    echo "  Waiting ${STAGGER_SECONDS}s before next miner..."
    sleep $STAGGER_SECONDS
  fi
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   All $MINER_COUNT miners started! Mining begins when all connected.  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Frontend:  http://localhost:8888"
echo "  RPC:       http://localhost:$RPC_PORT"
echo "  Wallets:   wallets/network_miners.json"
echo "  Logs:      data/logs/"
echo ""
echo "  To stop all: taskkill //F //IM omnibus-node.exe"
echo ""

# Keep script alive (shows status every 30s)
while true; do
  STATUS=$(curl -s -X POST http://localhost:$RPC_PORT -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"getstatus","params":[],"id":1}' 2>/dev/null || echo '{"result":{}}')
  BLOCKS=$(echo "$STATUS" | node -e "process.stdin.on('data',d=>{try{console.log(JSON.parse(d).result?.blockCount||0)}catch{console.log(0)}})" 2>/dev/null || echo "?")
  echo "[STATUS] $(date +%H:%M:%S) | Blocks: $BLOCKS"
  sleep 30
done
