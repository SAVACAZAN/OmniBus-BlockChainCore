# OmniBus AI Agent — User Journey

Acest document descrie *călătoria completă* a unui user nou care își configurează
propriul AI agent pe OmniBus blockchain — de la 0 OMNI până la arbitraj autonom.

> OmniBus este un blockchain **pentru AI, făcut de AI** — cei care tranzacționează
> sunt agenți autonomi. Userul nu tranzacționează direct: el pornește un nod și
> un agent, iar agentul evoluează automat prin tier-uri pe măsură ce capital crește.

## Tier-urile capabilităților

| Tier | Capital minim | Capabilități | Rol economic |
|------|---------------|--------------|--------------|
| **T1 Mining** | 0 OMNI | mining PoW + PoUW reports | acumulare inițială |
| **T2 Staking** | 100 OMNI | + stake validator, primește fees | securitate rețea |
| **T3 Liquidity** | 1.000 OMNI | + provide liquidity pe order book | adâncime piață |
| **T4 Arbitrage** | 10.000 OMNI | + arbitraj cross-exchange autonom | aliniere prețuri |

Hysteresis: agentul **nu coboară** un tier până când capitalul nu scade sub 90%
din pragul de intrare al tier-ului curent (evită oscilații pe fluctuații mici).

## Pasul 1 — Pregătire (o singură dată)

```bash
# Generează un mnemonic 24-word pentru wallet-ul tău (rămâne offline ideal)
omnibus-node --generate-wallet
# Output: {"address":"ob1q...","mnemonic":"word1 word2 ... word24"}
```

Salvează mnemonic-ul în SuperVault sau pe hârtie. Nodul îl citește automat
din Named Pipe (`OMNIBUS_VAULT_PIPE`) sau env var `OMNIBUS_MNEMONIC`.

## Pasul 2 — Scrie config-ul agentului

Creează `agent.json` (vezi `examples/agent.json` pentru template complet):

```json
{
  "agents": [
    {
      "name": "alpha",
      "wallet_index": 1,
      "strategy": "balanced",
      "auto_tier": true,
      "auto_claim_faucet": true,
      "tick_ms": 5000,
      "pairs": ["BTC/USD", "ETH/USD"],
      "risk": {
        "max_trade_pct": 5,
        "max_daily_loss_pct": 10
      },
      "rules": [
        { "metric": "btc_drop_1h_pct", "op": "gte", "threshold": 5.0,
          "action": "buy", "amount_pct": 10 }
      ]
    }
  ]
}
```

### Câmpuri explicate

- **wallet_index**: BIP-44 derivation index. `0` = wallet-ul nodului. Fiecare
  agent ar trebui să aibă index unic (1, 2, 3, ...).
- **strategy**: `conservative` / `balanced` / `aggressive` / `arbitrage_only` /
  `market_maker`. Determină comportamentul default per tier.
- **auto_tier**: `true` = agentul urcă singur tier-uri când capitalul crește.
  `false` = rămâne la tier-ul curent (sau la `tier_cap` dacă e setat).
- **auto_claim_faucet**: `true` = la prima rulare cu balance 0, agentul cere
  faucet (0.1 OMNI) automat.
- **rules**: liste de reguli deterministe — prima care se potrivește **trage**.
  Suprascriu strategia preset.

### Reguli deterministe

Format: `if <metric> <op> <threshold> then <action> <amount_pct%>`

**Metrici disponibile:**
- `btc_drop_1h_pct` — cât de mult a scăzut BTC în ultima oră (procent pozitiv).
- `btc_change_24h_pct` — variație BTC/USD în 24h (poate fi negativă).
- `capital_omni` — capital total al agentului (OMNI).
- `pnl_session_omni` — P&L sesiune curentă (OMNI, poate fi negativ).
- `spread_bps` — spread mediu pe perechea principală (basis points).

**Operatori:** `gt` `gte` `lt` `lte` `eq` (sau echivalente: `>`, `>=`, etc.)

**Acțiuni:** `buy`, `sell`, `stake`, `provide_liquidity`, `halt`.

## Pasul 3 — Pornire nod cu agent

```bash
omnibus-node --mode miner --node-id node-1 \
  --chain testnet \
  --agent-config agent.json
```

La start vei vedea:

```
[AGENT] 1 agent(i) incarcati din agent.json.
[MINER] Reward address: ob1q...
[MINING] Block 1 mined | reward 50 OMNI
[AGENT] alpha tier=t1_mining kind=claim_faucet amount=100000000 reason=bootstrap_faucet
```

Pe primul tick, agentul fără capital cere faucet automat. După câteva blocks
minate (50 OMNI/block, 1s/block), va trece pragul T2 și vei vedea:

```
[AGENT] alpha tier transition t1_mining -> t2_staking @ block 5 cap=100000000000 SAT
[AGENT] alpha tier=t2_staking kind=stake amount=199500000000 reason=preset_stake_idle
```

## Pasul 4 — Monitorizare

Agentul scrie pe stderr la fiecare tick non-trivial. Pentru status structurat,
RPC `agent_status` (în lucru — vezi follow-up below) va expune:

```json
{
  "name": "alpha",
  "tier": "t2_staking",
  "balance_sat": 50000000000,
  "staked_sat": 200000000000,
  "lp_locked_sat": 0,
  "pnl_session_sat": 0,
  "halted": false,
  "stats": {
    "ticks": 1234,
    "decisions_emitted": 980,
    "txs_submitted": 78,
    "tier_transitions": 1,
    "total_mined_sat": 250000000000
  }
}
```

## Pasul 5 — Kill switch & restart

```bash
# Halt manual (oprește decizii noi, păstrează state)
omnibus-cli agent halt --wallet-index 1

# Resume
omnibus-cli agent resume --wallet-index 1
```

Sau prin regulă auto-halt în config:

```json
{ "metric": "pnl_session_omni", "op": "lte", "threshold": -50.0,
  "action": "halt", "amount_pct": 100 }
```

(traducere: dacă pierd peste 50 OMNI într-o sesiune, oprește-te singur)

În plus, **risk.max_daily_loss_pct** declanșează auto-halt când agentul
pierde peste pragul setat (default 10%).

## Întrebări frecvente

**Pot avea mai mulți agenți pe același nod?** Da, până la 16. Fiecare cu propriul
`wallet_index`. Vezi `examples/agent.json` cu 2 agenți.

**Ce face agentul dacă nu am `pairs` declarate?** Pentru tier T1/T2 nu contează
(mining + staking nu cer pereche). Pentru T3+ trebuie cel puțin o pereche, altfel
agentul rămâne în mining pasiv.

**Pot scrie reguli care contrazic strategia preset?** Da. Regulile au prioritate.
Strategia preset rulează doar dacă **nicio regulă** nu se potrivește în tick-ul
curent.

**Risk limits sunt opționale?** Nu — au defaults siguri (5% max trade, 10% daily
loss limit). Le poți override, dar nu poți scoate complet.

**Unde se păstrează state-ul agentului?** State-ul (tier curent, P&L sesiune,
stats) trăiește în memorie. La restart, agentul recalculează tier-ul din capital
(ledger e sursa de adevăr). Decizii vechi nu sunt re-executate.

## Status implementare (actualizat 2026-04-27)

### Done end-to-end
- [x] `agent_tier.zig` — tier-uri T1→T4 cu hysteresis (6 teste OK)
- [x] `agent_config.zig` — JSON parser + 5 strategii preset (13 teste OK)
- [x] `agent_executor.zig` — loop decizional + Venue enum (22 teste OK)
- [x] `agent_manager.zig` — manager + queue + receipts (112 teste OK)
- [x] `agent_wallet.zig` — derivare BIP-44 m/44'/777'/0'/0/N per agent (77 teste OK)
- [x] `--agent-config` CLI flag în `cli.zig`
- [x] Wiring în `main.zig` mining loop (tick pe fiecare bloc)
- [x] **Wallet per-agent**: fiecare agent are adresă bech32 proprie (ob1q...) derivată din `wallet_index`
- [x] **TX submission automat** pentru venue=omnibus_native (`submitNativeTx`)
- [x] RPC: `agent_list`, `agent_status`, `agent_pending_decisions`, `agent_report_execution`
- [x] Python client extern `2_SDK/omnibus-sdk/omnibus_sdk/onchain_agent/` (LCX/Kraken/Coinbase via Connect SDK UnifiedWrapper)

### Wallet derivation per-agent
Fiecare agent are adresă proprie derivată automat la `--agent-config`:
```
[AGENT] Loaded alpha | wallet_index=1 | addr=ob1q5h7... | tier=t1_mining
[AGENT] Loaded beta  | wallet_index=2 | addr=ob1qkz3... | tier=t1_mining
[AGENT-NATIVE] alpha tier=t1_mining kind=mine amount=0 reason=preset_mine
[AGENT-TX] alpha signed tx_id=5000001 amount=10000 nonce=1
```
**Important:** `wallet_index=0` e wallet-ul nodului. Agenții folosesc 1, 2, 3, ...

### Deferred (nice-to-have, nu blochează MVP)
- [ ] Stake/unstake real prin staking_engine API (acum: log-only)
- [ ] Frontend tab "Agents" în BlockChainCore (RPC există)
- [ ] Frontend tab "AI Agents" în aweb3 (modul nou separat)
- [ ] LP/withdraw_liquidity wired la matching engine
- [ ] Tests E2E: nod + Python client + LCX testnet
