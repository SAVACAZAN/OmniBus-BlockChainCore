# omnibus-cli — Tutorial pas cu pas

Ghid practic în română pentru `omnibus-cli`. Tutorialele folosesc adresa reală
de mining a fondatorului (`ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0`,
`savacazan.omnibus`) și nodul testnet public `omnibusblockchain.cc:8443`.

> **Important:** binarul `omnibus-cli` din v0.3.0-dev este **read-only** —
> interoghează lanțul, nu semnează tranzacții. Pentru fluxurile care semnează
> (stake, register .omnibus, plasare ordin DEX) folosești fie aweb3 (Tauri),
> fie `curl` direct cu un payload semnat. Tutorialele care semnează indică
> explicit unde se folosește un alt tool decât CLI-ul.

---

## Getting started — instalare și prima comandă

### 1. Build

```sh
cd 1_CORE/BlockChainCore
zig build install                  # produce zig-out/bin/omnibus-cli(.exe)
./zig-out/bin/omnibus-cli --help
```

### 2. Adaugă în PATH (Linux/macOS)

```sh
sudo cp zig-out/bin/omnibus-cli /usr/local/bin/
omnibus-cli --help
```

Pe Windows pune `zig-out\bin\` în `%PATH%` sau copiază `omnibus-cli.exe` în
`C:\Windows\System32\`.

### 3. Setează default-uri

Creează `~/.omnibus/cli.conf` (UTF-8, format `KEY=VALUE`):

```
OMNIBUS_RPC_URL=http://127.0.0.1:8332
OMNIBUS_CHAIN=mainnet
# OMNIBUS_RPC_TOKEN=<bearer> — doar dacă nodul tău cere autentificare
```

Wrapper-ul shell (Bash/Zsh/Fish completions) citește acest fișier și
adaugă automat `--rpc` / `--chain` / `--token`.

### 4. Prima comandă — sănătatea lanțului

```sh
# Local
omnibus-cli health

# Sau VPS-ul live testnet
omnibus-cli --remote --chain testnet health
```

Dacă vezi `Sync status: SYNCED` și o înălțime > 1, ești gata.

---

## Tutorial 1: Verifică balanța (chain reality vs UI)

**Scenariu:** UI-ul aweb3 zice că ai 1245 OMNI, dar nu ești sigur că nu cache-uiește.
Vrei adevărul chain-ului.

```sh
# Adresa ta de mining (BIP-44 #0)
ADDR="ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0"

omnibus-cli balance "$ADDR"
```

**Output așteptat:**
```
=== Balance: ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 ===
Wallet:    1245.0000 OMNI
Staked:    325.0000 OMNI (active)
Available: 920.0000 OMNI

Reputation: 8421 / 1,000,000  Tier OMNI
  LOVE:     12.45 / 100
  FOOD:     8.10 / 100
  RENT:     0.00 / 100
  VACATION: 4.20 / 100
```

**Interpretare:**
- `Wallet` = total din UTXO (chain).
- `Staked` = subset locked în `getstake.stakes[]`.
- `Available` = `Wallet − Staked` (cât poți cheltui).
- `Reputation` și `Cups` = soulbound, derivate din activitate (mining, agents, ENS).

**Pro tip — verifică toate adresele tale dintr-un fișier:**
```sh
while read addr; do
  echo "--- $addr ---"
  omnibus-cli balance "$addr"
done < ~/.omnibus/known_addresses
```

---

## Tutorial 2: Stake OMNI (semnare în aweb3, verificare cu CLI)

**Pas 1: stake-uire** (în aweb3 sau via RPC semnat — CLI-ul nu semnează):

În aweb3 → tab "Stake" → introduce sumă (ex: 100 OMNI) → "Confirm". Tauri
semnează cu BIP-44 path `m/44'/777'/0'/0/0` și apelează `stake_lock`.

**Pas 2: verifică în chain (CLI):**
```sh
omnibus-cli stake "$ADDR"
```

**Output:**
```
=== Stake: ob1q...zp0 ===
Current stake: 425.0000 OMNI (active)

Recent stake activity:
  block    1820  +100.0000 OMNI  STAKE    abcdef01...
  block    2300  +200.0000 OMNI  STAKE    bcdef012...
  block    3105  + 25.0000 OMNI  STAKE    cdef0123...
  block    4250  +100.0000 OMNI  STAKE    def01234...

Running total: 425.0000 OMNI (matches chain)
```

**Pas 3: sanity check final:**
```sh
omnibus-cli verify "$ADDR"
```

Codul de ieșire `0` = totul OK; `1` = state desincronizat (vezi Tutorial 7).

**Unstake:** același pattern — semnezi în aweb3, verifici cu `omnibus-cli stake`.
Vei vedea o linie `-X.XXXX OMNI UNSTAKE` în activitate.

---

## Tutorial 3: Înregistrează un nume `.omnibus`

**Scenariu:** Vrei `savacazan.omnibus` legat de adresa ta.

> **Notă:** Înregistrarea se face în aweb3 (sau prin `curl` cu TX semnat).
> Comanda `ns_register` nu este încă wrap-uită în CLI.

**Pas 1: rezolvă prin RPC raw** (verifică dacă numele e liber):
```sh
curl -sS http://127.0.0.1:8332 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ns_resolve","params":{"name":"savacazan.omnibus"}}' \
  | jq .
```

Dacă `result` e `null` → e liber. Dacă apare un `owner`, e luat.

**Pas 2: înregistrează din aweb3** → tab "Names" → introdu `savacazan.omnibus`
→ achiți fee-ul (5 OMNI mainnet, 0.1 OMNI testnet) → confirmă.

**Pas 3: confirmă în chain:**
```sh
# Verifică TX-ul în istoric
omnibus-cli history "$ADDR" all | grep ns_register

# Vezi noul nume
curl -sS http://127.0.0.1:8332 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ns_resolve","params":{"name":"savacazan.omnibus"}}' \
  | jq .result
```

---

## Tutorial 4: Trade pe DEX

**Scenariu:** Vinzi 10 OMNI contra USDC pe pair_id 0 (OMNI/USDC).

> **Notă:** Plasarea ordinului semnează un TX → folosești aweb3, nu CLI.
> CLI-ul ajută la **monitorizare**.

**Pas 1: vezi piețele active:**
```sh
curl -sS http://127.0.0.1:8332 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"exchange_pairs","params":[]}' \
  | jq .
```

Sau, în CLAUDE.md ai lista fixă: `0=OMNI/USDC, 2=LCX/USDC, 3=ETH/USDC, 5=OMNI/LCX, 6=OMNI/ETH`.

**Pas 2: plasezi ordinul în aweb3** → tab "DEX" → pair OMNI/USDC →
sell 10 @ price = best ask − 0.5%.

**Pas 3: monitorizează fill-urile cu CLI:**
```sh
# Activitatea ta zilnică
omnibus-cli daily "$ADDR" 1

# Doar tranzacțiile (în istoric apare ca fill cu kind=swap_settle)
omnibus-cli history "$ADDR" all | head -20
```

**Pas 4: orderbook live** (raw RPC):
```sh
curl -sS http://127.0.0.1:8332 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"exchange_orderbook","params":{"pair_id":0}}' \
  | jq '.result | {bids: .bids[:5], asks: .asks[:5]}'
```

---

## Tutorial 5: Rulează un agent

**Scenariu:** Vrei să register un agent AI (smart-contract JSON) și să primești
recompense când userii îl folosesc.

> **Notă:** `agent_register` semnează → aweb3. Aici doar urmărești.

**Pas 1: înregistrare în aweb3** → tab "Agents" → upload JSON spec →
plătește fee → confirmă.

**Pas 2: verifică:**
```sh
# Tranzacțiile de tip agent_register apar în history
omnibus-cli history "$ADDR" all | grep agent

# Recompensele agentului apar ca received în daily
omnibus-cli daily "$ADDR" 30
```

**Pas 3: dacă ai stake la agent (locking):**
```sh
omnibus-cli stake "$ADDR"
# Liniile cu STAKE care nu sunt validator stake sunt agent locks.
```

---

## Tutorial 6: Cross-chain swap OMNI → ETH

**Scenariu:** Vrei să schimbi 50 OMNI contra ETH pe Sepolia, atomic via HTLC.

> **Notă completă:** Vezi `DEX_GRID_SPEC.md`. Flow:
> 1. aweb3 cheamă `htlc_init` cu `pair_id=6, side=ask, amount=50`.
> 2. Chain-ul Zig generează preimage și `hash_lock`.
> 3. Tu trimiți tranzacția pe Sepolia cu același `hash_lock`.
> 4. Counterparty redeem-uiește pe Sepolia → preimage revelat.
> 5. Chain settle-uiește OMNI-ul tău automat.

**Cu CLI-ul actual** monitorizezi swap-ul în `daily`:
```sh
omnibus-cli daily "$ADDR" 1
# Verifici stakeΔ și cantitățile sent/received pentru ziua curentă.
```

**Status-ul HTLC** (raw RPC):
```sh
curl -sS http://127.0.0.1:8332 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"swap_status","params":{"swap_id":"0xabc..."}}' \
  | jq .
```

---

## Tutorial 7: Audit zilnic — rapoarte CSV

**Scenariu:** Vrei un raport zilnic CSV pentru contabilitate / portofoliu.

```sh
# Daily breakdown ultimele 30 zile, JSON brut
omnibus-cli --json daily "$ADDR" 30 > daily.json

# Convertește în CSV cu jq (history are .transactions[])
omnibus-cli --json history "$ADDR" all \
  | jq -r '.result.transactions[] | [.blockHeight,.kind,.direction,.amount,.fee,.txid] | @csv' \
  > tx_history.csv
```

**Watch live (refresh la 5s):**
```sh
watch -n 5 omnibus-cli balance "$ADDR"
```

**Reputation diff (zilnic):**
```sh
# La 23:59 salvezi snapshot-ul de azi
omnibus-cli --json reputation "$ADDR" > "rep_$(date +%F).json"

# Mâine compari
diff <(jq .result.total < rep_2026-05-09.json) \
     <(jq .result.total < rep_2026-05-10.json)
```

---

## Tutorial 8: Devino validator

**Scenariu:** Stake-uiești 100+ OMNI și vrei să apari în setul de validatori.

**Pas 1: stake 100 OMNI** în aweb3 (sau via TX semnat).

**Pas 2: așteaptă ~10 blocuri** (consensul își actualizează setul).

**Pas 3: verifică în CLI:**
```sh
omnibus-cli validators | grep "$ADDR"
```

Dacă apari în listă cu `weight ≥ 100` și `since_h ≤ <current_height>`, ești
validator activ. Vei începe să primești sub-block rewards.

**Pas 4: verifică totalul tău în top stakers:**
```sh
omnibus-cli stakers 20 | grep "$ADDR"
```

**Pas 5: monitorizare uptime** (raw RPC, nu e încă în CLI):
```sh
curl -sS http://127.0.0.1:8332 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getvalidatorsv2","params":[]}' \
  | jq --arg a "$ADDR" '.result.validators[] | select(.address == $a)'
```

> Tier-ul de validator nu e doar despre stake — vezi
> `STATUS/PROJECT_OMNIBUS_VALIDATOR_VISION.md`. Cap 1M reputație + uptime
> tiebreaker decid ladder-ul (OMNI → LOVE → FOOD → RENT → VACATION).

---

## Power user — scripting cu jq

### Toate adresele care au minat în ultimele 7 zile

```sh
omnibus-cli --json daily "$ADDR" 7 \
  | jq -r '.result.transactions[]
           | select(.kind == "coinbase" or .kind == "mined")
           | .blockHeight'
```

### Profit din stake (rewards) ultimele 30 zile

```sh
omnibus-cli --json history "$ADDR" all \
  | jq -r '.result.transactions[]
           | select(.kind == "stake_reward")
           | .amount' \
  | awk '{ s+=$1 } END { printf "Total: %.4f OMNI\n", s/1e9 }'
```

### Validators sortați după weight (desc)

```sh
omnibus-cli --json validators \
  | jq -r '.result.validators
           | sort_by(-.weight)
           | .[]
           | "\(.address)  weight=\(.weight)  since=\(.since_height)"'
```

### Watch reputation tier change

```sh
while true; do
  TIER=$(omnibus-cli --json reputation "$ADDR" | jq -r .result.tier)
  echo "$(date +%T)  $TIER"
  sleep 60
done
```

### Pipeline: alertă Discord când balanța > 1000 OMNI

```sh
BAL=$(omnibus-cli --json balance "$ADDR" \
      | jq '.balance.result.balance / 1e9')
if (( $(echo "$BAL > 1000" | bc -l) )); then
  curl -X POST "$DISCORD_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "{\"content\":\"Balance alert: $BAL OMNI\"}"
fi
```

---

## Trouble­shooting

| Eroare | Cauză & soluție |
|--------|-----------------|
| `Cannot reach RPC at http://127.0.0.1:8332 ... Is omnibus-node running?` | Nodul nu rulează. Pornește cu `./zig-out/bin/omnibus-node --mode seed`. |
| `RPC error: method not found` | Nod versiune veche; update la `0.3.0-dev`. |
| `MISMATCH chain=...` la `verify` | State a fost wipe-uit înainte de replay. SSH în nod, restart cu replay forțat. |
| `curl spawn failed (is curl in PATH?)` | `--remote` cere `curl`. Instalează-l (Linux: `apt install curl`, Windows: PATH). |
| Output fără culori chiar și cu TTY | Setase `NO_COLOR=1` în env, sau `--no-color` activ. |

---

## Pas următor

- Citește `docs/CLI_REFERENCE.md` pentru descrierea exhaustivă a fiecărei comenzi.
- Vezi `docs/CLI_COOKBOOK.md` pentru flow-uri gata făcute (CSV export, alerts, monitoring).
- Pentru fluxurile de semnare (stake/swap/ENS) deschide aweb3 sau citește
  `API_REFERENCE.md` să trimiți TX-uri raw cu `curl`.
