# Next Session Plan — Slot Calendar + SPARK Sub-Block Consensus

**Sesiunea curentă (28 Apr 2026)** a livrat fundațiile clock-ului unic:

- `core/orchestrator.zig` — AtomicClock + TimeOrchestrator + clockScore60s + RDTSC + binarySpectrum (16 unit tests, all pass)
- Mining loop folosește `g_clock.nowMs()` peste tot (slot-leader, stabilizer, burst smoothing)
- `ws_exchange_feed` wired la `&g_clock` prin `setClock()`
- Stabilizer raportează `clock_score = X/100` + bit-spectrum live la fiecare 60s

**Rezultat măsurat pe VPS testnet:**

| Metric | Sesiunea anterioară | Sesiunea aceasta |
|--------|---------------------|------------------|
| Block rate | 15/min | **48/min** |
| Best block | unknown | **76ms** |
| p50 latency | unknown | **231ms** |
| Sub-1s blocks | 0% | **88%** |
| Sub-100ms blocks | 0% | **5%** |
| Clock score | n/a | **61-100/100** (vizibil VPS jitter) |

**Commits pushed (gitea + vps):**

- `aab28fa` — slot-leader fixes + stabilizer
- `162131a` — orchestrator integration (Step 1+2)
- `b363095` — sleep eliminated + clockScore60s + burst smoothing (Step 4)
- `0606de8` — RDTSC + binary spectrum + ws-feed clock (Step 5)

---

## Pentru sesiunea următoare

### 1. Pre-Computed Slot Calendar (Solana PoH-style)

**Conceptul** — la t=now, generăm map-ul pentru next 60 slots:

```zig
pub const SlotEntry = struct {
    slot_id: u64,
    leader: ?Validator,         // deterministic via leaderForSlot()
    expected_arrival_ms: i64,    // now + N × 1000
    placeholder_hash: [32]u8,    // empty until block lands
    state: enum { future, in_flight, finalized, missed },
};

pub const SlotCalendar = struct {
    entries: [60]SlotEntry,
    head: usize, // ring buffer
};
```

**De ce ajută:**

1. Frontend poate afișa "next leader: ob1qzhrauq0x in 2.3s"
2. Future-block pool — TX-uri marcate cu `target_slot=N` intră direct în slot-ul corect
3. Pre-warmed signature template — leader-ul își pre-semnează block header gol
4. Anti-fork: ceilalți validatori știu deja cine ar trebui să livreze fiecare slot

**Effort estimat:** 1-2 ore pentru read-only calendar + log; 1 zi cu future-block pool;
3-5 zile cu pre-warmed signature templates.

**Riscuri** (din discuția anterioară):

| Risc | Mitigare |
|------|----------|
| Reorg invalidează slots pre-computate | Pre-compute doar slot-uri >= 6 confirmations din tip |
| Leader change la governance TX | Calendar regenerat după fiecare governance TX |
| Memory pressure | Cap fix max 60 slot-uri viitoare |
| Timing attack — TX cu target_slot distant | Window limit max 10s în viitor + fee per slot |
| Determinism break | Tot calendar-ul vine din `slot_id + tip_hash + validator_set` |

### 2. SPARK Sub-Block Consensus (viziunea ta)

**Idee centrală** — cele 10 sub-blocks devin **10 layere de validare paralelă**, nu sleep:

> "Cine ajunge primul să mineze + alți noduri verifică în 10 sub-blocks dacă block-ul e
>  conform Ada SPARK consensus (balanță reală, no double spend, etc.)"

**Layout sub-blocks:**

| Sub-block | Verificare Ada SPARK |
|-----------|----------------------|
| #1 | TX batch + well-formed check |
| #2 | UTXO existence (sender chiar are coin-uri) |
| #3 | No double-spend (UTXO not already spent) |
| #4 | Signature verify (ECDSA + Schnorr + PQ) |
| #5 | Nonce monotonic |
| #6 | Aggregate balance constraint (sum_in = sum_out + fee) |
| #7 | Smart contract state (dacă există) |
| #8 | Cross-shard receipts |
| #9 | Reputation / trust score check |
| #10 | Final merkle root + commit |

**Ada SPARK contract example:**

```ada
procedure Verify_Block (B : Block; OK : out Boolean)
   with Pre  => Is_Well_Formed (B),
        Post => OK = (No_Double_Spend (B)
                  and All_Balances_Valid (B)
                  and All_Signatures_Valid (B)
                  and Nonces_Monotonic (B));
```

SPARK demonstrează la **build-time**:

- Funcția nu poate da fals positive (toate condițiile verificate)
- Nu există overflow în calcul balanțelor
- Nu există race conditions

**Voting protocol:**

- Fiecare sub-block produce ATTEST/REJECT cu signature
- 6 din 10 ATTEST → block finalizat cu high trust
- 5/10 → low trust mode, ținut în limbo
- <5/10 → REJECT, leader pierde reputation

**Late arriver** (alt block competitor în același slot):

- Acceptăm dar cu penalty pe reputation, sau reject după check
- Low trust mode = block valid dar nu poate fi cu count >= K confirmations până nu trece audit ulterior

**Effort:**

- Faza A (sub-block voting protocol în Zig): 3-5 zile
- Faza B (Ada SPARK linkage la Zig prin C ABI): 1 săpt
- Faza C (low-trust mode + reputation penalty): 1 săpt

Avem deja **300+ fișiere Ada SPARK** în `1_CORE/refs/ada-spark/ada 300 files/code/`
care urmează același pattern (database, audit, balances) — pot fi adaptate
pentru block verification.

### 3. Detalii tehnice per platform pentru clock

| Platform | Clock primar | Latency | Resolution |
|----------|-------------|---------|------------|
| Linux VPS (acum) | `std.time.milliTimestamp()` | ~50-200ns | 1ns |
| Linux upgrade | `std.posix.clock_gettime(CLOCK_MONOTONIC)` via vDSO | ~50ns | 1ns |
| Windows dev | `QueryPerformanceCounter` | ~80ns | ~100ns |
| Baremetal x86_64 | `rdtscp` inline ASM | ~10ns | ~0.3ns @ 3GHz |
| Baremetal ARM | `cntvct_el0` inline ASM | ~10ns | depends on counter freq |

Verificare formală via Ada SPARK pentru contracte (monotonic guaranteed,
no overflow, drift bounded).

### 4. UI spectrum visualizer

Endpoint nou RPC `clock_spectrum` care livrează la frontend bit-pattern-ul
ultimilor 1000 ticks → vizualizare în UI ca spectrum analyzer:

- High bits stabile = sistem sănătos
- Broken bit patterns = scheduler pause / frequency scaling / hypervisor migration

Util pentru a documenta vizual de ce baremetal e necesar pentru sub-100ms latency
consistent.

---

## Order of operations recomandat pentru sesiunea următoare

1. **Slot calendar read-only** (1-2 ore) — log "next 10 slots, leader X, expected arrival Y"
2. **Spectrum RPC endpoint** (1-2 ore) — frontend să poată afișa în timp real
3. **Future-block pool** (1 zi) — TX cu `target_slot` intră direct în slot
4. **Sub-block voting protocol** (3-5 zile) — 10 ATTEST/REJECT votes per slot
5. **Ada SPARK linkage** (1 săpt) — C ABI între Zig și Ada
6. **Low-trust mode** (1 săpt) — reputation penalty + delayed finality

---

**Ultima zonă pe explorer (28 Apr 2026 ~19:30 UTC):**

- Block height: ~58_300+
- Miner activ: `ob1qw6zh**tqxlvl` (VPS)
- PC `ob1qzhrauq0x` offline
- Clock score variabil 61-100 (VPS jitter)
- Burst smoothing 100ms activ
