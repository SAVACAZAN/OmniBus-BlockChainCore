# omnibus-cli — Cookbook

Recipe-style examples for common workflows. All snippets target the v0.3.0-dev
binary built from `core/cli_audit.zig` (9 subcommands: `balance`, `stake`,
`reputation`, `daily`, `validators`, `stakers`, `health`, `history`, `verify`).

Set this once at the top of your shell session:

```sh
ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"   # your wallet
export OMNIBUS_RPC_URL="http://127.0.0.1:8332"      # local node
# or, against the public testnet VPS:
# alias omnibus-cli="omnibus-cli --remote --chain testnet"
```

---

## 1. Live monitoring

### Watch wallet balance every 5 seconds

```sh
watch -n 5 omnibus-cli balance "$ADDR"
```

### Tail chain health while a node syncs

```sh
watch -n 2 omnibus-cli health
# Or stop watching once SYNCED:
until omnibus-cli --json health | jq -e '.result.synced // (.result.peerCount > 0)' >/dev/null; do
  sleep 2
done
echo "Node is ready."
```

### Track validator weight live

```sh
watch -n 10 "omnibus-cli --json validators \
  | jq -r '.result.validators[] | \"\\(.address) weight=\\(.weight)\"'"
```

---

## 2. CSV / spreadsheet exports

### Daily activity → CSV (last 30 days)

```sh
omnibus-cli --json history "$ADDR" all \
  | jq -r '
      ["block","kind","direction","amount_omni","fee_omni","txid"],
      (.result.transactions[]
       | [.blockHeight, .kind, .direction,
          (.amount/1e9), (.fee/1e9), .txid])
      | @csv
    ' > tx_history.csv
```

### Daily summary (per-day buckets)

`daily` already aggregates in the binary. Use `--json` to feed jq:

```sh
omnibus-cli --json daily "$ADDR" 30 \
  | jq -r '
      ["day","tx_count","sent_omni","received_omni","mined_omni","fees_omni","stake_delta_omni"],
      (.result.transactions
       | group_by(.blockHeight / 86400 | floor)
       | map({
           day: .[0].blockHeight / 86400 | floor,
           count: length,
           sent: ([.[] | select(.direction=="sent") | .amount] | add // 0),
           received: ([.[] | select(.direction=="received") | .amount] | add // 0),
           mined: ([.[] | select(.kind=="coinbase" or .kind=="mined") | .amount] | add // 0),
           fees: ([.[] | .fee] | add // 0),
           stake: (([.[] | select(.kind=="stake") | .amount] | add // 0)
                  - ([.[] | select(.kind=="unstake") | .amount] | add // 0))
         })
       | .[]
       | [.day, .count, (.sent/1e9), (.received/1e9),
          (.mined/1e9), (.fees/1e9), (.stake/1e9)])
      | @csv
    ' > daily_summary.csv
```

### Reputation snapshot per address (batch)

```sh
{
  echo "address,total,tier,love,food,rent,vacation"
  while read addr; do
    omnibus-cli --json reputation "$addr" \
      | jq -r --arg a "$addr" '
          .result
          | [$a, .total, .tier,
             .cups.love, .cups.food, .cups.rent, .cups.vacation]
          | @csv
        '
  done < ~/.omnibus/known_addresses
} > reputations_$(date +%F).csv
```

---

## 3. Filtering & search

### Mining rewards in last 7 days

```sh
# Block range = last 7 days @ 1s blocks = 86400 * 7 = 604800
HEIGHT=$(omnibus-cli --json health | jq '.result.height')
SINCE=$(( HEIGHT - 604800 ))

omnibus-cli --json history "$ADDR" mined \
  | jq --arg since "$SINCE" '
      .result.transactions
      | map(select(.blockHeight >= ($since | tonumber)))
    '
```

### Sum mined OMNI in the last 30 days

```sh
HEIGHT=$(omnibus-cli --json health | jq '.result.height')
SINCE=$(( HEIGHT - 30 * 86400 ))

omnibus-cli --json history "$ADDR" mined \
  | jq --arg s "$SINCE" '
      [.result.transactions[]
       | select(.blockHeight >= ($s | tonumber))
       | .amount]
      | add / 1e9
    '
```

### TXs above 100 OMNI

```sh
omnibus-cli --json history "$ADDR" all \
  | jq '.result.transactions
        | map(select(.amount > 100000000000))
        | .[] | {block: .blockHeight, kind, dir: .direction,
                 omni: (.amount/1e9), txid}'
```

---

## 4. Multi-validator monitoring

### Print "address tier uptime%" for all validators

```sh
omnibus-cli --json validators \
  | jq -r '.result.validators[]
           | "\(.address)  weight=\(.weight)  since_h=\(.since_height)"'
```

### Detect validator joins (diff snapshots)

```sh
# Take a snapshot now
omnibus-cli --json validators | jq -r '.result.validators[].address | sort' \
  > /tmp/vals_now.txt

# Diff against yesterday's snapshot
diff /tmp/vals_yesterday.txt /tmp/vals_now.txt | grep '>' \
  | sed 's/> /NEW VALIDATOR: /'
```

---

## 5. Auto-actions (one-liners)

### Auto-stake when balance > 100 OMNI

```sh
# This pattern detects opportunity; the actual stake TX is signed via aweb3.
# Hook a notifier:
BAL_OMNI=$(omnibus-cli --json balance "$ADDR" \
           | jq '.balance.result.balance / 1e9')
if (( $(echo "$BAL_OMNI > 100" | bc -l) )); then
  notify-send "OmniBus" "You can stake $BAL_OMNI OMNI now"
  # Or post to webhook:
  # curl -X POST "$WEBHOOK" -d "{\"text\":\"Stake $BAL_OMNI OMNI\"}"
fi
```

### Restart node when `verify` fails

```sh
if ! omnibus-cli verify "$ADDR" >/dev/null; then
  echo "Stake state out of sync — restarting node"
  systemctl --user restart omnibus-node
fi
```

### Daily Discord report (cron @ 23:55)

```sh
#!/usr/bin/env bash
DATE=$(date +%F)
SUMMARY=$(omnibus-cli --no-color daily "$ADDR" 1 | tail -n +2)
curl -sS -X POST "$DISCORD_WEBHOOK" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg s "$SUMMARY" --arg d "$DATE" \
        '{content: "**\($d)**\n```\n\($s)\n```"}')"
```

---

## 6. Backups

### Backup wallet metadata (chain-side view)

```sh
mkdir -p ~/.omnibus/backups
DATE=$(date +%F)
{
  echo "# OmniBus chain snapshot for $ADDR @ $DATE"
  echo
  echo "## balance"
  omnibus-cli --json balance "$ADDR"
  echo
  echo "## stake"
  omnibus-cli --json stake "$ADDR"
  echo
  echo "## reputation"
  omnibus-cli --json reputation "$ADDR"
  echo
  echo "## history (full, capped at 200 by CLI)"
  omnibus-cli --json history "$ADDR" all
} > "$HOME/.omnibus/backups/snapshot_${DATE}.json"
```

> **Note:** This only backs up *chain-side* state (balance, stake, history,
> reputation). Your seed phrase + PQ keys live in SuperVault / aweb3 — the
> CLI cannot read or write them.

### Track reputation growth

```sh
DATE=$(date +%F)
omnibus-cli --json reputation "$ADDR" \
  | jq --arg d "$DATE" '{date: $d, total: .result.total, tier: .result.tier, cups: .result.cups}' \
  >> "$HOME/.omnibus/rep_log.jsonl"

# Plot growth (requires gnuplot)
jq -r '[.date, .total] | @tsv' < "$HOME/.omnibus/rep_log.jsonl" \
  | gnuplot -p -e 'plot "<cat" using 1:2 with linespoints title "Reputation"'
```

---

## 7. Cross-environment

### Same command against mainnet, testnet, regtest

```sh
for chain in mainnet testnet regtest; do
  echo "--- $chain ---"
  omnibus-cli --chain $chain health 2>/dev/null \
    | grep -E 'Height|Validators|Sync' \
    || echo "(unreachable)"
done
```

### Compare local vs VPS (tip drift)

```sh
LOCAL=$(omnibus-cli --json health | jq '.result.height')
VPS=$(omnibus-cli --remote --chain testnet --json health | jq '.result.height')
echo "Local: $LOCAL  VPS testnet: $VPS  diff: $(( VPS - LOCAL ))"
```

---

## 8. Troubleshooting recipes

### "RPC unreachable" — find which port works

```sh
for port in 8332 18332 28332; do
  echo -n "Port $port: "
  if omnibus-cli --rpc "http://127.0.0.1:$port" health >/dev/null 2>&1; then
    echo OK
  else
    echo FAIL
  fi
done
```

### "Chain mismatch" — find the offender

```sh
omnibus-cli verify "$ADDR" || {
  echo "Drilling into stake history..."
  omnibus-cli stake "$ADDR" | grep -E 'STAKE|UNSTAKE'
}
```

### Estimate sync ETA

```sh
START=$(omnibus-cli --json health | jq '.result.height')
sleep 60
END=$(omnibus-cli --json health | jq '.result.height')
PEER=$(omnibus-cli --json health | jq '.result.peerHeight // .result.height')
RATE=$(( END - START ))                 # blocks per minute
REMAINING=$(( PEER - END ))
if [ $RATE -gt 0 ]; then
  echo "Sync rate: $RATE blocks/min, ETA: $(( REMAINING / RATE )) minutes"
else
  echo "Not syncing (rate=0)"
fi
```

---

## 9. Integration

### Prometheus textfile collector

```sh
#!/usr/bin/env bash
# /etc/cron.d/omnibus-metrics — every minute
ADDR="ob1q...zp0"
OUT=/var/lib/node_exporter/textfile_collector/omnibus.prom

omnibus-cli --json balance "$ADDR" | jq --arg a "$ADDR" -r '
  "omnibus_balance_omni{address=\"\($a)\"} \(.balance.result.balance / 1e9)",
  "omnibus_stake_omni{address=\"\($a)\"} \([.stake.result.stakes[].amount_sat] | add // 0 | . / 1e9)",
  "omnibus_reputation{address=\"\($a)\"} \(.reputation.result.total)"
' > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
```

### Slack daily digest

```sh
TXT=$(omnibus-cli --no-color daily "$ADDR" 7)
curl -X POST "$SLACK_WEBHOOK" \
  --data-urlencode "payload={\"text\":\"\`\`\`$TXT\`\`\`\"}"
```

---

## 10. Power moves

### Top 3 mining wallets in the network (by mined coinbase count)

> The `getrichlist` RPC isn't yet wrapped, so use raw RPC:

```sh
curl -sS http://127.0.0.1:8332 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getrichlist","params":[]}' \
  | jq -r '.result.richlist[:3][] | "\(.address)  mined=\(.total_mined)"'
```

### "Did anything change since last check?"

```sh
HASH_NOW=$(omnibus-cli --json balance "$ADDR" | sha256sum | cut -d' ' -f1)
HASH_OLD=$(cat ~/.omnibus/last_balance_hash 2>/dev/null || echo none)
if [ "$HASH_NOW" != "$HASH_OLD" ]; then
  echo "$HASH_NOW" > ~/.omnibus/last_balance_hash
  omnibus-cli balance "$ADDR"
fi
```

### Sanity-check every known address in parallel

```sh
xargs -P 8 -I {} sh -c '
  if omnibus-cli verify {} >/dev/null 2>&1; then
    echo "OK   {}"
  else
    echo "FAIL {}"
  fi
' < ~/.omnibus/known_addresses
```
