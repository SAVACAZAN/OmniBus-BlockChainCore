# Prompt for Kimi — alternative architectures for OmniBus block-rate problem

Copy-paste the section below into Kimi (or any external LLM). Asks for
2-3 alternative designs we could swap into the chain to hit our timing
target without throwing away the existing codebase.

---

## CONTEXT

I'm building **OmniBus**, a Layer-1 blockchain written in **Zig 0.15.2**
on Linux (testnet seed runs on a shared-CPU VPS, ~2 GHz invariant TSC,
2 cores, 1 GB RAM). The repo has ~80k LoC of Zig across `core/*.zig`.

### Architecture (current, working)

- **Block model**: Bitcoin-style PoW with difficulty=1 on testnet. Each
  block targets **1 second** wall-clock. Inside each block we run a
  10-tick **sub-block** loop (was 75ms × 10 = 750ms, now 0ms — sub-blocks
  are pure TX-batching, no real-time pacing).
- **Slot leader rotation**: deterministic via
  `leaderForSlot(slot_id, prev_block_hash, validators)` — SHA-256 of
  (slot_id || prev_hash) mod weighted-validator-set.
- **Liveness fallback**: if leader is silent past `SLOT_TIMEOUT_MS` (300
  ms by default, 50 ms when peer offline), the lex-smallest validator
  takes the slot.
- **Single source of time**: `core/orchestrator.zig` exposes
  `AtomicClock` (real or fake backend), `nowCycles()` (rdtscp inline asm
  on x86_64), `binarySpectrum` (bit-level visualisation),
  `clockScore60s` (0-100 health metric for a 60s span),
  `calibrateTscPerSec` (one-shot at startup → ~2 GHz on the VPS),
  `TimeOrchestrator` (5 named timers: slot, sub_block, shard,
  ws_exchange, stabilizer; with skip-when-late semantics so a 500ms GC
  pause produces 1 firing, not 12 catch-up firings).
- **SlotCalendar**: ring of next 60 slots, deterministic leader per
  slot, refreshed states (future / in_flight / finalized / missed).
  Rebuilt every 10 blocks for amortised cost.
- **Stabilizer**: per-block ring buffer of the last 3600 arrival
  timestamps. Reports 1-min and 60-min rolling rates every 60s and
  tunes a `timeout_mult` ∈ [0.2, 2.0] proportional to (observed/target).
- **TCP_NODELAY** is now set on all P2P sockets (inbound + outbound).
- **Burst smoothing**: minimum 100 ms between consecutive blocks
  produced by us, **only when we're at-or-above target rate**. Below
  target → free burst, no smoothing (lets the chain catch up after VPS
  scheduler pauses).
- **DB persistence**: removed from the hot path entirely. The
  blockchain itself is the database; balances/nonces/pubkey-registry
  are deterministically replayed from chain on startup. Restart resyncs
  from peers.

### Cryptographic stack

- secp256k1 ECDSA (pure Zig, ~80 KB), bech32 (`ob1q…` addresses)
- BIP-32 HD wallets, BIP-39 mnemonic, optional 25th-word passphrase
- liboqs PQ wrappers (ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768)
  for future migration
- SHA-256 for block hashes + merkle roots; software impl, no
  Intel SHA-NI yet
- Schnorr + BLS aggregation also implemented but unused at consensus
  level today

### Performance, measured

| Metric                | This session start | Now              |
| --------------------- | ------------------ | ---------------- |
| Block rate            | 15 blocks/min      | 42–50 blocks/min |
| Best-case latency     | unknown            | 76 ms            |
| Median (p50) latency  | unknown            | 231 ms           |
| Sub-1 s blocks        | 0%                 | 88%              |
| Sub-100 ms blocks     | 0%                 | ~5%              |
| Clock health (60s span) | unknown          | 47–100 / 100     |

The **target is 60 blocks per minute exactly** — clock-precise: every
60 seconds we want exactly 60 blocks, every block exactly 1 second
apart, with 10 sub-blocks per block. Like an atomic clock dripping
into a ledger.

### Recent commit history (newest first)

The block-rate work happened in this exact order. The measurements
column is what each change moved the rate to in 60-second windows on
the same VPS (jitter band ±10 blocks, sometimes ±20 during bad VPS
windows).

| Commit    | Summary                                                              | Rate after        |
| --------- | -------------------------------------------------------------------- | ----------------- |
| `aab28fa` | slot-leader fixes + stabilizer (timeout 3s→0.3s, lex-min tiebreak)   | 33–35/min         |
| `162131a` | orchestrator integration (single AtomicClock, 5 timers)              | 32–35/min         |
| `b363095` | sub-block sleep removed + clockScore60s + burst smoothing 100ms      | 34–48/min         |
| `0606de8` | RDTSC cycle counter + binary spectrum + ws-feed wired to clock       | 45–48/min (best!) |
| `9872951` | docs only (NEXT_SESSION_PLAN)                                        | n/a               |
| `e2e5a2a` | slot calendar + 3 RPC endpoints + future-block pool                  | 36/min  ← regression |
| `3104f5b` | calendar throttle (rebuild every 10 blocks) + adaptive smoothing     | 50/min            |
| `d0138be` | UI tab "Roadmap" (iframe to pyramid+hourglass)                       | n/a (frontend)    |
| `e78a525` | fix RPC URL in roadmap-flow                                          | n/a               |
| `61ea4da` | wooden hourglass model 2 + legend + log-scaled pyramid               | n/a (frontend)    |
| `261c5d6` | TCP_NODELAY on P2P sockets + TSC calibration at startup              | 42–50/min         |

### Best ever observed (and lost)

The user reports having seen up to **58 blocks/min** at one point, but
they don't remember exactly which commit. Looking at the history, the
candidate window is between `0606de8` (RDTSC + ws-feed-to-clock,
45-48/min observed) and `e2e5a2a` (calendar regression to 36/min).

The slot calendar in `e2e5a2a` cost ~12 blocks/min because it was
calling `leaderForSlot` (a SHA-256 hash) 60 times per block. The
follow-up `3104f5b` recovered most of that loss by throttling rebuild
to every 10 blocks. We may still be a few blocks/min below the peak
because the calendar rebuild is now amortised but still on the hot
path.

### Best vs worst observed in a single run

- **Best block latency**: 76 ms (from 0606de8 onward)
- **Median latency**: 231 ms in the best windows
- **Worst single-block latency**: 18,775 ms (one of the bad VPS
  scheduler pause spikes — process literally suspended for 18 seconds)
- **Best 1-min window**: ~50 blocks
- **Worst 1-min window during the same hour**: ~15 blocks
- **Worst "60 minutes total"**: as low as 480 blocks, vs. target of 3600

### Persistent problem

Even with all the above, on the shared VPS the rate is **42–50/min,
not 60**. Inspection of the logs shows the cause is exclusively
**hypervisor scheduler starvation** — every few minutes the process is
suspended for 5–18 seconds, during which no block can be produced.
`clock_score` drops to 47–60/100 in those windows; bursts fire as soon
as we resume but the smoothing ceiling caps them.

This is **not a code problem**. On dedicated hardware (e.g. a
baremetal Linux machine or our planned OmniBus OS) we expect to hit
60/min comfortably and the architecture supports much higher (the
sub-block loop is 0 ms per tick now; each block is bounded by PoW at
diff=1 plus state apply, ~50–200 µs typical).

But I want to validate the architecture itself. The current model is
roughly:

1. **PoW + slot-leader rotation** (deterministic per slot, with
   liveness fallback to lex-min validator on timeout).
2. **Sub-blocks as pure TX batching** (10 batches per slot, aggregate
   merkle root, no individual broadcast).
3. **Best-effort gossip with TCP_NODELAY** for low-latency block
   announces.
4. **Self-tuning timeout multiplier** based on observed-vs-target rate.
5. **JSON-RPC 2.0** + a Kraken-compatible REST surface for exchange
   semantics.

### What I want from you

Please give me **2–3 concrete alternative architectures** I could
adopt, each with:

- **Name + 1-line summary** (e.g. "Tendermint-style BFT with 1s
  rounds", "HotStuff with pipelined commits", "Solana PoH with
  rotating leaders", "Aptos AptosBFT with parallel execution",
  "Narwhal/Bullshark mempool-DAG", etc.)
- **Why it would (or wouldn't) hit 60 blocks/min on shared CPU**
- **What I'd have to throw away** from the current codebase
- **What I'd have to add**, in concrete Zig modules, with rough LoC
  estimate and difficulty
- **Real-world chains that ship this design** today
- **Specific weak spots** the design has that ours doesn't, so I can
  weigh the trade-off honestly

Then a final **comparison table** with columns:
*Design / Throughput ceiling / Latency floor / Code reuse from
current / Maintenance burden / Production-readiness*

I am NOT looking for:

- Generic "write everything in Rust / Go" advice — Zig is a chosen
  constraint.
- Framework-level recommendations (no "use Substrate", no "use
  Cosmos SDK") — we're staying L1-from-scratch.
- "Add a dashboard" — we have one.
- "Use C++/Ada/SPARK for the timer" — we already use rdtscp inline
  asm in Zig; this is not a language problem.

I AM looking for designs where the **consensus + slot model itself**
is different, and where the trade-off makes sense for our use case
(small validator set 2–10 nodes, 1 s target, JSON-RPC compatibility,
PQ-ready signatures, eventual baremetal port).

Be blunt about which option you'd actually pick if it were your
project.
