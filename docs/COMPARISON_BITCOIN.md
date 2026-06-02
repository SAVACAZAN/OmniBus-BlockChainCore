# OmniBus Blockchain vs Bitcoin — Master Blueprint Comparison (140 puncte)

Comparație punct cu punct între **Bitcoin** și **OmniBus Blockchain**, structurată pe cele 14 capitole din anatomia clasică Bitcoin extinsă cu infrastructură fizică, ecosistem, L2 și filozofie.

> **Status:** OmniBus e în bootstrap. Bitcoin e matur (16+ ani, 600 EH/s). Comparația arată direcția arhitecturală, nu paritate de scale.

---

## 1. Fundația Criptografică (Inima Sistemului)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 1 | Hashing | SHA-256 | SHA-256 (compatibil) + SHA-3/Keccak în zone PQ |
| 2 | Semnături | ECDSA secp256k1 | ECDSA secp256k1 + 4× PQ (ML-DSA-87, Falcon-512, Dilithium-5, SLH-DSA-256s) |
| 3 | Chei pub/priv | Da | Da, **multiplicate ×5** — 1 ECDSA + 4 PQ derivate din același mnemonic |
| 4 | Format adresă | Base58Check + Bech32 | Bech32 `ob1q…` + 4 prefixe PQ (`obk1_/obf5_/obd5_/obs3_`) |
| 5 | RIPEMD-160 | Da | Da (pentru OMNI primary) |
| 6 | Entropy | CSPRNG | CSPRNG (chain) + OS RNG pentru PQ keypair |
| 7 | Schnorr | Da (Taproot) | Schnorr disponibil + BLS pentru agregare |
| 8 | Taproot | Da | Echivalent prin scheme PQ |
| 9 | HD Wallets | BIP-32/39/44 | BIP-32/39/44 + 19 chain-uri derivate |
| 10 | PQ ready | Doar discuții, nu wired | **LIVE** — 4 algoritmi NIST FIPS 203/204/205 prin liboqs |

**Diferență cheie:** Bitcoin e single-key. OmniBus e **5-key per identitate** (1 transferable + 4 soulbound), toate derivate din același seed.

---

## 2. Rețeaua P2P (Sistemul Nervos)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 11 | Full nodes | Da | Da (`omnibus-node.exe`) |
| 12 | Gossip | Da | Da + Tor-ready cu HELLO/WELCOME/STABLE peer recognition |
| 13 | DNS Seeds | Da | Per-chain seed (port 9000/9001/9002) |
| 14 | Mempool | FIFO | FIFO + sig-verify la intake (real, nu lazy) |
| 15 | Orphan blocks | Da | Da + sub-block engine (10×0.1s → 1 keyblock) |
| 16 | INV messages | Da | Da, peer scoring activ |
| 17 | Bridges | Sidechains externe | **Native** — atomic swap OMNI↔BTC↔ETH (HTLC live) |
| 18 | Latency | ~10 min/bloc | **1s sub-block, 10s keyblock** |
| 19 | Sybil | Cost economic | **Knock-knock UDP** — 1 miner/IP + sybil_fee_path activ |
| 20 | Eclipse | Risc real | Mitigat prin peer scoring + Tor optional |

**Diferență cheie:** OmniBus are **anti-Sybil agresiv** (1 miner per IP) și **bridge-uri native** (nu wrapped tokens).

---

## 3. Proof of Work (Motorul de Securitate)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 21 | Difficulty adj | 2016 blocuri | Per-block adjustment (scădere mai rapidă) |
| 22 | Nonce | u32 | u32 + extranonce |
| 23 | Target hash | Da | Da |
| 24 | ASIC | Dominant | **Anti-ASIC** preferință (CPU-friendly proof) |
| 25 | Hashrate | ~600 EH/s | Bootstrap (10 noduri/30 zile grace period) |
| 26 | Energy | ~150 TWh/an | Mult mai mic prin sub-blocks |
| 27 | Pools | Da (Stratum V1/V2) | Da, mining-pool Node.js + Stratum V2 gateway în OmniBus OS |
| 28 | Coinbase TX | 50→3.125 BTC | 50 OMNI, halving la 210k blocuri |
| 29 | Halving | 210k blocuri | Identic (210k blocuri) |
| 30 | 51% attack | Cost ~$10B | Cost mic acum — protejat prin **5-tier validator ladder** + uptime tiebreaker |

**Diferență cheie:** OmniBus combină PoW cu **PoUW share** (Proof of Useful Work) și 5-tier validator system.

---

## 4. Structura de Date (Arhivele)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 31 | Block header | 80 bytes | Similar + sub-block field |
| 32 | Merkle Tree | Da | Da + state trie separat |
| 33 | Merkle Root | Da | Da |
| 34 | Genesis | 03-Jan-2009 | Genesis block per chain (placeholder pentru mainnet) |
| 35 | UTXO | UTXO model | **Account-based** (balances HashMap) — mai aproape de ETH |
| 36 | Pruning | Da | **WIP** — partial save per-block |
| 37 | Block height | Da | Da |
| 38 | Chainwork | Da | Da |
| 39 | TXID | SHA-256 dublu | SHA-256 (single) cu canonical hash |
| 40 | Witness Data | SegWit | Native — semnătura PQ separată de tx body |

**Diferență cheie:** OmniBus folosește **account model** (ca ETH), nu UTXO. Trade-off: mai simplu de programat agenți AI, pierzi unele proprietăți de privacy.

---

## 5. Bitcoin Script vs OmniBus JSON Contracts (Logica/Programarea)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 41 | Limbaj | Stack-based Script | **JSON smart contracts** (format OpenAI tool spec) |
| 42 | OP_CODES | OP_DUP, OP_CHECKSIG | `op_return:` prefixes (`stake:`, `agent:register`, `notarize:`, `sub_create:`) |
| 43 | ScriptPubKey | Da | Echivalent în account state |
| 44 | ScriptSig | Da | Signature + public_key în TX |
| 45 | Multisig | P2SH 2-of-3 | **M-of-N multisig live** |
| 46 | Time-locks | nLockTime | Per-subscription `next_block` + escrow expiry |
| 47 | Turing | Incomplete (intenționat) | **Incomplete** prin design (JSON contracts cu reguli predefinite) |
| 48 | P2WPKH | Bech32 | `ob1q…` Bech32 native |
| 49 | Dead man switch | Da | Soulbound + auto-recovery via PQ proof |
| 50 | Miniscript | Da | N/A — JSON e simplu prin design |

**Diferență cheie:** OmniBus NU are Solidity/EVM. Smart contracts sunt **JSON declarative** executate de agenți AI nativ în chain (genesis: `ens_register_v1`, `agent_license_v1`, `staking_lock_v1`).

---

## 6. Teoria Jocurilor & Economie (Stimulentele)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 51 | Unitate minimă | Satoshi (1e-8) | **SAT** (1e-9, 1 OMNI = 1B SAT) |
| 52 | Stock-to-Flow | Da | Identic (halving) |
| 53 | Deflație | 21M cap | **21M cap OMNI** (identic) |
| 54 | Fees | Doar miner | **Split**: miner + treasury (registrar slot #2 `exchange.omnibus`) |
| 55 | Selfish mining | Risc | Mitigat prin validator tier |
| 56 | Incentive compat | Da | Da + reputation economy (4 pahare 0-100) |
| 57 | Gresham | Da | Identic |
| 58 | Hard money | Da | Da |
| 59 | Fungibility | Problemă | **Voluntar non-fungibil** prin reputation tiers |
| 60 | Lindy | 16+ ani | Bootstrap, fără Lindy încă |

**Diferență cheie:** OmniBus are **reputation economy** (LOVE/FOOD/RENT/VACATION 0-100, total 0-1M, "Satoshi badge" la 100/100/100/100). Bitcoin n-are așa ceva.

---

## 7. Scalabilitate și Layer 2 (Viteza)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 61 | Lightning | L2 separat | **Payment channels native** (persisted) |
| 62 | Payment channels | LN | Native on-chain |
| 63 | State channels | Limitat | Native + intent broadcast |
| 64 | Watchtowers | Da (LN) | Echivalent prin agenți AI |
| 65 | HTLC | Da | **HTLC live cross-chain** |
| 66 | Liquid Network | Da | Native — DEX cross-chain integrat |
| 67 | Block size | 1MB/4MB | 128KB max request, 100KB tx (PQ size budget) |
| 68 | SegWit | Da | Native witness separation pt PQ |
| 69 | Rollups | Incipient | N/A — 4 shards native |
| 70 | Atomic swaps | Da | **Native cross-chain** (5-agent sweep) |

**Diferență cheie:** Tot ce e L2 în Bitcoin (LN, RGB, Stacks) e **L1 native** în OmniBus. Trade-off: chain mai complex, mai puțin auditat.

---

## 8. Atacuri și Reverse Engineering (Puncte Slabe)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 71 | Pre-image | Imposibil cu SHA-256 | Identic |
| 72 | TX malleability | Fix prin SegWit | Canonical hash via `transaction.zig:calculateHash` |
| 73 | Dust attack | Risc | Mitigat prin minim TX size |
| 74 | Chain analysis | Da (Chainalysis) | Da, dar PQ identitate ascunde split-uri cross-chain |
| 75 | Cold storage | Da | Da + vault PIN cu Argon2id+AES-GCM |
| 76 | Hardware wallet | Ledger/Trezor | În roadmap (sidebar-cpp = SuperVault DPAPI) |
| 77 | Social eng | Risc #1 | Identic, plus PQ recovery options |
| 78 | Quantum threat | **Vulnerabil** ECDSA | **Imun** prin 4 PQ schemes |
| 79 | BGP hijack | Risc | Mitigat prin Tor optional |
| 80 | Double spend | Mempool sync | Sub-block pre-confirm + mempool sig verify |

**Diferență cheie:** Bitcoin are **vulnerabilitate cuantică** (ECDSA va cădea în Y-năr cuantic). OmniBus e **PQ-hardened by default**.

---

## 9. Guvernanță și Dezvoltare (Cine decide?)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 81 | BIPs | Da | OmniBus modules + memory_map.toml |
| 82 | Core team | Voluntari | Founder (Alex Cazan) + 9 AI co-authors |
| 83 | Soft fork | Da | Da |
| 84 | Hard fork | Risc (BCH) | Posibil, controlat de validator ladder |
| 85 | UASF | Da | DAO governance module on-chain |
| 86 | Signet | Da | **Testnet activ** (port 18332/18333) |
| 87 | Testnet | Da | Da + regtest (port 28332) |
| 88 | Open source | Da | Da (Gitea + GitHub mirror) |
| 89 | Checkpointing | Da | Per-block save partial |
| 90 | Consensual upgrade | Lent | DAO vote on-chain |

**Diferență cheie:** OmniBus are **DAO governance native** (votare on-chain), Bitcoin are politică off-chain.

---

## 10. Privacy & Tehnologii Obscure

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 91 | CoinJoin | Da (Wasabi) | N/A nativ |
| 92 | Tor | Optional | **Native HELLO/WELCOME/STABLE** flow |
| 93 | Stealth addr | Da | OMNI Quantum sub-addr (4 transferable: `obk1_/obf5_/obd5_/obs3_`) |
| 94 | Confidential TX | Liquid | N/A |
| 95 | Dandelion++ | Da | În roadmap |
| 96 | Brain wallets | Riscant | Mnemonic + vault double-protect |
| 97 | Multisig escrow | Da | **Escrow live** (`escrow_create`/`release`/`refund`/`dispute`) |
| 98 | Payjoin | Da | N/A |
| 99 | OP_RETURN | 80 bytes max | **Liber** — folosit pentru NS, notarize, subscriptions, stake, agent |
| 100 | Ordinals/NFT | Da | În roadmap (OmniBus OS module `status_token_os`) |

---

## 11. Infrastructura Fizică (Hardware & Energie)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 101 | ASIC competition | 3-5nm | CPU-friendly anti-ASIC |
| 102 | Energy sources | Flare gas, hydro | N/A până la scale |
| 103 | Mining farms | Massive | Bootstrap |
| 104 | Satellite | Blockstream | În roadmap |
| 105 | Radio mesh | Da | N/A |
| 106 | Hardware signers | Trezor | SuperVault (sidebar-cpp) |
| 107 | RPi nodes | Da | Da (Zig binary, lightweight) |
| 108 | Submarine cables | Da | Identic |
| 109 | Storage | 600GB+ | Mult mai mic acum |
| 110 | Grid stabilization | Da | N/A |

---

## 12. Stratul de Interfață & Servicii (Ecosistemul)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 111 | Block explorer | Mempool.space | **omnibusblockchain.cc:8443** + frontend custom |
| 112 | Custodians | Fidelity, Coinbase | Self-custody only by design |
| 113 | Payment gw | BTCPay | În aweb3 (RPC native) |
| 114 | ATMs | Da | N/A |
| 115 | On-chain analytics | Chainalysis | RichList + Reputation public |
| 116 | Oracles | Limitat | **Native** — DistributedPriceOracle (BTC/ETH/OMNI) |
| 117 | Bridges | Wrapped BTC | **Native** atomic swap |
| 118 | P2P exchanges | Bisq | **Native DEX** — 8 RPC `exchange_*` + signed orders |
| 119 | Notarization | OP_RETURN hack | **Native** — `notarizedoc/verifynotarize/revokenotarize` |
| 120 | Wallet recovery | Limitat | Mnemonic + vault dual-recovery |

**Diferență cheie:** OmniBus are **DEX nativ** + **Oracle nativ** + **Notarization nativ**. La Bitcoin toate sunt L2/extern.

---

## 13. Layer 2 & Protocoale Extinse (Inovația)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 121 | Lightning nodes | Mii | Native channels module |
| 122 | Nostr | Separat | În roadmap (OmniBus OS) |
| 123 | Ordinals | Da | În roadmap |
| 124 | BRC-20 | Da, controversial | N/A — JSON contracts native |
| 125 | Stacks (STX) | Externă | OmniBus = native smart contracts |
| 126 | Rootstock | EVM externă | aweb3 + Hardhat (EVM compat optional) |
| 127 | RGB Protocol | Da | N/A |
| 128 | Federated sidechains | Liquid | 4 shards native (metachain) |
| 129 | Atomic swaps | În LN | **L1 native** |
| 130 | Statechains | Experimental | N/A |

---

## 14. Filozofia & Social (Psihologia)

| # | Concept | Bitcoin | OmniBus |
|---|---------|---------|---------|
| 131 | Cypherpunk | Da | Da + AI co-authoring (9 modele) |
| 132 | Proof of existence | OP_RETURN | **Native notarization RPC** |
| 133 | Libertarianism | Strong | Identic + reputation-based |
| 134 | Austrian econ | Da | Identic |
| 135 | Decentralization | Real | Bootstrap (10 noduri/30 zile grace) |
| 136 | Open source | Da | Da (Gitea self-hosted) |
| 137 | Education | Vast | Omni-Pedia wiki (100 wiki files planned) |
| 138 | Regulation | Hostile | **eIDAS-aligned** prin 4× PQ + identity manifest |
| 139 | HODL culture | Da | Soulbound = HODL forced (4 wallet-uri) |
| 140 | Sovereignty | "Be your own bank" | **"Be your own bank + notar + DEX + identity"** |

---

## Verdictul scurt

**Bitcoin** = bani digitali sound, single-purpose, monolith, defensiv.

**OmniBus** = **superset al Bitcoin** + Ethereum (smart contracts JSON) + Lightning (channels native) + Liquid (atomic swap) + ENS (.omnibus names) + DEX nativ + identitate post-cuantică + reputation economy + AI agents native.

### Trade-off-uri reale

| Avantaj OmniBus | Cost OmniBus |
|-----------------|--------------|
| Mult mai multă funcționalitate native | Mult mai puțin auditat (Bitcoin are 16 ani) |
| PQ-ready acum, nu peste 10 ani | Bootstrap (hashrate mic, 51% atacabil ieftin acum) |
| Bridge-uri native fără wrapped tokens | Account model = trade-off privacy vs UTXO Bitcoin |
| DEX/Oracle/Notar nativ on-chain | Complexitate mai mare = surface attack mai mare |
| Reputation economy + soulbound identity | Lipsă Lindy effect (proba timpului) |
| eIDAS-aligned prin 4× PQ | Centralizare bootstrap (founder + 10 noduri) |

### Scopul filozofic

Bitcoin a fost gândit ca **bani digitali rezistenți la cenzură**. OmniBus e gândit ca **infrastructura financiară completă post-cuantică** — bani + identitate + smart contracts + DEX + oracle + notar într-un singur L1, cu agenți AI ca executori nativi.

Bitcoin câștigă pe simplitate, audit, Lindy. OmniBus pariază pe **integrare verticală** + **PQ-first** + **AI-native execution**.

---

## Referințe în cod

- Crypto: [`core/secp256k1.zig`](core/secp256k1.zig), [`core/pq_crypto.zig`](core/pq_crypto.zig), [`core/wallet.zig`](core/wallet.zig)
- Consensus: [`core/sub_block.zig`](core/sub_block.zig), [`core/finality.zig`](core/finality.zig), [`core/staking.zig`](core/staking.zig)
- DEX nativ: [`core/rpc_server.zig`](core/rpc_server.zig) (`exchange_*` RPC group)
- Notarization: [`core/notarize.zig`](core/notarize.zig)
- Subscriptions: [`core/subscription.zig`](core/subscription.zig)
- Multisig + Channels: [`core/multisig.zig`](core/multisig.zig), [`core/channels.zig`](core/channels.zig)
- Atomic swaps: [`core/htlc.zig`](core/htlc.zig)
- Oracle: [`core/price_oracle.zig`](core/price_oracle.zig)
- Identitate PQ: [`core/isolated_wallet.zig`](core/isolated_wallet.zig), `pq_attest` RPC
- DAO: [`core/governance.zig`](core/governance.zig)
- P2P: [`core/p2p.zig`](core/p2p.zig), [`core/peer_scoring.zig`](core/peer_scoring.zig)

Documentație extinsă: [`ARCHITECTURE_DUAL_OS.md`](ARCHITECTURE_DUAL_OS.md), [`MASTER_PROMPT_KIMI_CLAUDE.md`](MASTER_PROMPT_KIMI_CLAUDE.md), parent [`CLAUDE.md`](../../CLAUDE.md).

---

*Document generat 2026-05-07. Status OmniBus: bootstrap testnet (omnibusblockchain.cc:8443).*
