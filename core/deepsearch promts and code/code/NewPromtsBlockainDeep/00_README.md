# NewPromtsBlockainDeep — Stare proiect OmniBus L1

Director generat: 2026-05-19
Repo: `1_CORE/BlockChainCore`
Branch curent: `feat/onchain-orderbook`

## Scopul acestui director

Snapshot al proiectului OmniBus L1 raportat la promptul original "ce vreau să avem ca L1 production-grade".
Fiecare fișier acoperă o axă diferită:

| Fișier | Conținut |
|--------|----------|
| `00_README.md` | Acest fișier — index și legenda statusurilor |
| `01_STATUS_IMPLEMENTED.md` | Module deja funcționale în `core/*.zig` (156 fișiere Zig) |
| `02_STATUS_IN_PROGRESS.md` | Module parțial implementate sau în curs |
| `03_GAP_ANALYSIS.md` | Ce lipsește din promptul original — mapat pe module concrete de creat |
| `04_NEXT_STEPS_PROMPTS.md` | Prompt-uri executabile pentru fiecare modul lipsă, în ordine de prioritate |

## Legenda statusurilor

- ✅ **DONE** — modul există, are teste, e wired în `main.zig` sau folosit de alt modul
- 🟡 **PARTIAL** — există dar minimal, lipsesc feature-uri sau wiring
- 🔴 **MISSING** — nu există în `core/`, trebuie creat
- 🟣 **EXPERIMENTAL** — există în alt director (`code/` cu prefix numeric) ca draft, neintegrat

## Context arhitectural

OmniBus e **L1 propriu** (matching engine + notary), nu wallet multi-chain.
Modulele wallet-style (BTC native, SOL, TON) sunt opționale — dacă vrem produs "wallet complet"
mai bine le punem într-un repo separat `wallet-core/` care depinde de `core/` doar pentru BIP-32 +
crypto primitives.

Vezi `03_GAP_ANALYSIS.md` pentru decizia finală: ce intră în `core/` și ce intră în `wallet-core/`.
