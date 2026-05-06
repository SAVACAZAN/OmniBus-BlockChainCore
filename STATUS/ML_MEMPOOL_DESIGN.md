# ML Mempool Anomaly Detector — Design (v1)

Status: DESIGN ONLY. Nothing to be built/trained/committed from this document.
Scope: detection model + integration plan for the OmniBus mempool.
Author: blockchain-ai-trainer agent.

---

## 1. Problem statement

Goal: per-TX anomaly score in `[0.0, 1.0]` produced at the moment a TX hits the mempool (in `Mempool.add` after structural validation, before FIFO insertion). The score does NOT change consensus — it is advisory metadata used for:

1. RPC introspection (`mempool_anomaly_score(txhash)`).
2. Optional soft policy (rate-limit / quarantine queue) — opt-in, off by default.
3. Operator dashboards / alerting.

Hard rule: the model must NEVER reject a TX that the consensus rules would accept. False positives here have a real cost (legit users get throttled). Detection is a hint layer, not a gate.

### 1.1 Threat model — what we are detecting

| Class | Signature in mempool | Why it matters |
|---|---|---|
| **Spam flood** | One sender (or N sybils) bursting many small-amount, min-fee TXs | Bloats the 1 MB mempool, evicts honest TXs |
| **Fee griefing** | TXs at exactly `TX_MIN_FEE_SAT=1` with high `size_bytes`, low ratio | Forces honest users to bid up fees |
| **Sybil burst** | Many distinct senders, all freshly funded, identical TX shape, tight time window | Coordinated, intent unclear (often pre-MEV staging) |
| **RBF abuse** | High-frequency `replaceByNonce` on same `(sender, nonce)` slot — fee bumps every few seconds | DoS on validator CPU (constant re-hashing/re-validation) |
| **Pinning** | Low-fee parent + child chain via `nonce+1` to block CPFP eviction | Classic Bitcoin Core attack class — `getPackageFee` already exposes the hooks |
| **Dust attack** | Many `amount = 1 SAT` TXs to varied recipients | Address-graph deanonymization probe |
| **Payload abuse** | `tx_type != .transfer` with maximum 4 KiB `data` repeated rapidly | Bloats orderbook / bridge / HTLC subsystems |

Everything else (pure protocol violations) is already handled by `tx.isValid()` and `validatePayload`. The model only sees TXs that already passed those.

---

## 2. Feature vector

Computed at `Mempool.add` time, AFTER structural validation, BEFORE FIFO insert. All features deterministic from `tx`, current mempool state, and a small rolling-window sender index (a sidecar struct, NOT persisted).

Total: **35 dims** (12 numeric + 20 one-hot tx_type + 3 binary).

### 2.1 Numeric features (12)

| # | Name | Source | Notes |
|---|---|---|---|
| 1 | `fee_per_byte` | `tx.fee / estimateTxSize(&tx)` | Q16.16 fixed-point, clamped to `[0, 65535]` |
| 2 | `fee_vs_median` | `tx.fee / mempool.medianFee()` | Already exposed; clamped `[0, 16x]` |
| 3 | `size_bytes_norm` | `estimateTxSize / TX_MAX_BYTES` | `[0,1]` |
| 4 | `amount_log2` | `log2(tx.amount + 1)` | discretized 0..63 |
| 5 | `sender_pending_count` | `mempool.getPendingCount(tx.from_address)` | already exposed |
| 6 | `sender_tx_count_60s` | rolling window per-sender counter | NEW sidecar (see 4.3) |
| 7 | `sender_tx_count_600s` | rolling window per-sender counter | NEW sidecar |
| 8 | `time_since_last_sender_tx` | `now - last_seen[from]` | NEW sidecar; capped 3600 |
| 9 | `nonce_gap` | `tx.nonce - (chain_nonce + pending_count)` | negative = replacement, large positive = future-nonce hoarding |
| 10 | `op_return_len` | `tx.op_return.len` | 0..80 |
| 11 | `data_len_norm` | `tx.data.len / MAX_TYPED_PAYLOAD` | `[0,1]` |
| 12 | `output_count` | `tx.outputs.len` | 0..256 |

Fee-per-byte is the single most discriminating feature (literature on Bitcoin spam is unanimous). Sender velocity in 60s window catches the flood class. `nonce_gap` catches RBF abuse and future-nonce parking.

### 2.2 TX type one-hot (20)

20 slots, one per `TxType` discriminant currently defined (`transfer`, `order_place`, `order_cancel`, `order_modify`, `bridge_lock`, `bridge_deposit_report`, `bridge_unlock_request`, `bridge_unlock_sign`, `bridge_fraud_challenge`, `htlc_init`, `htlc_claim`, `htlc_refund`, `intent_post`, `intent_fill_commit`, `intent_settle`, `intent_timeout`, `tss_dkg_commit`, `tss_dkg_finalize`, `tss_vault_rotate`, `governance`). Unknown discriminants land in a 21st `_other` bucket — but since `validatePayload` already rejects unknown types, this slot is dead in practice.

### 2.3 Binary flags (3)

- `is_rbf_replacement` — true if the TX displaces an existing entry with same `(from, nonce)`. Hook: the existing RBF branch in `mempool.zig:97-120`.
- `is_cpfp_child` — true if `mempool.hasChildBoost(&parent)` would fire for this TX's `nonce-1` ancestor.
- `min_fee_exact` — true if `tx.fee == TX_MIN_FEE_SAT` (1 SAT). Strong spam signal in combination with high `size_bytes_norm`.

### 2.4 Excluded on purpose

- `sender_balance` — proposed in the task, but reading UTXO/state per-incoming-TX adds I/O on the hot path. Low marginal value vs. velocity features. **Skip.**
- `sig_count` — schema exposes a single `signature` field (multisig is via `script_sig` envelope). Encode indirectly via `tx_type` + `script_sig.len` if needed in v2.
- Geographic / peer-of-origin — leaks across nodes, breaks determinism of the score across the network. The score must be reproducible from `(tx, local mempool snapshot)` only.

---

## 3. Model choice

**Decision: gradient-boosted decision tree (LightGBM, ~200 trees, depth 6).**

### 3.1 Why GBDT

- Inference latency: ~1-5 µs for 200 trees × depth 6 on a modern x86 — well under the implicit budget. The 100 ms budget mentioned in the task is for whole-pipeline including I/O; the model itself is essentially free.
- Mixed feature scales handled natively (no normalization required for numeric; categorical one-hots are fine).
- Probabilistic output (sigmoid of margin) → scale to `[0.0, 1.0]` for the RPC response.
- Trees can be exported as a flat array of `{feature_idx, threshold, left, right, leaf_value}` records — straightforward to embed as a `comptime` array in Zig if we ever want to move inference in-process. Initial deployment is sidecar (see §5), so this is just a future-proofing point.
- Does not need GPU, does not need floats at inference — comparison + integer accumulation only (after we re-quantize thresholds + leaf values to i32 fixed-point Q16.16 to match the bare-metal rules in `omni_brain.zig`).

### 3.2 Why not MLP

A 35-dim → 64 → 32 → 1 MLP works fine on the classification, but:

- Requires float-to-fixed-point requantization with attention to activation overflow (extra engineering).
- Worse interpretability — operators cannot answer "why did this TX score 0.87?". GBDT trees can dump the decision path.
- No measurable accuracy gain on this kind of low-dim, high-skew tabular data.

Skip MLP for v1. Keep as v3 option if we ever pull in graph features (see §4.4).

### 3.3 Why not isolation forest / OCSVM

Pure unsupervised would let us avoid the labeling problem (§4) — but isolation forest tunes poorly on heavily imbalanced operational data and produces no probability calibration. We will use it only as a comparison baseline, not the deployed model.

---

## 4. Training data plan

### 4.1 Real "normal" baseline

Source: replay `omnibus-chain.dat` blocks via `core/database.zig` + `core/binary_codec.zig`. For each historical block, reconstruct the mempool state at `block.timestamp - 10s` and emit a feature vector for every TX that ended up in the block. Label these `0` (benign).

Rationale: a TX that was actually mined into a finalized block on mainnet/testnet is, by construction, not anomalous from a network-policy point of view.

Bias warning: this excludes TXs that were **rejected** before mining. If those rejection reasons are spam-class, our "negative class" is artificially clean. Mitigation: we have no rejected-TX log persisted today, so bias is unavoidable in v1. Add `mempool_rejection_log.dat` (out of scope for this design) before v2.

Estimated volume: testnet currently around 20-50k TXs total, mainnet ~unknown but assume <500k after a year. **This is small for ML.** Sufficient for a 200-tree GBDT, insufficient for a deep model — another reason GBDT is the right call.

### 4.2 Synthetic "anomalous" class

Generated by a script `tools/gen_synthetic_anomalies.py` (NOT to be written as part of this design):

| Class | Generator |
|---|---|
| Spam flood | One sender, 1000 TXs in 60s, fee=1, amount=1000 SAT |
| Sybil burst | 100 distinct senders, 1 TX each in 5s window, identical amount |
| RBF storm | One `(sender, nonce)` slot, 50 replacements in 30s with fee bumping by 1 SAT |
| Pinning | parent (fee=1, large size) + child (fee=1, depends on parent's nonce) |
| Dust spray | 500 TXs to 500 distinct recipients, amount=1 SAT each |
| Payload bomb | 100 `order_place` TXs with maximum 4 KiB `data`, all from same sender |

Label all synthetic TXs `1` (anomalous). Ratio target: synthetic ≈ 10-20% of training set. Higher ratios make the model trigger-happy (bad — see false-positive risk below).

### 4.3 Sidecar rolling-window structure (also needed at inference time)

```
SenderWindow {
  HashMap<address, RingBuffer<i64>>   // last 64 timestamps per sender, 600s TTL
}
```

Memory bound: 10 000 active senders × 64 × 8 B = 5 MB. Acceptable. Eviction: drop entries older than 600s on each `add`. This struct is **not** persisted across restarts — initial state is empty, model treats first-seen-after-restart senders as cold (`sender_tx_count_60s = 0`).

### 4.4 Optional v2 graph features

Address-graph clustering across 24h windows (input: `from→to` edges from chain history). Adds ~5 features. Skip in v1 — adds an offline batch job and a graph DB dependency we don't have today.

---

## 5. Deployment plan

**Decision: Python sidecar with HTTP/Unix-socket scoring API. NOT in-process.**

### 5.1 Topology

```
core/mempool.zig (Zig node)
   │  on add(tx) → POST /score {features...} → returns {score: 0.87}
   ▼
ml-sidecar/ (Python, LightGBM, port 8336)
   │  loads models/mempool-anomaly-v1.json on startup
   ▼
score returned to RPC layer, attached as metadata
```

Sidecar runs as a separate process (systemd unit on the VPS, alongside the existing 3 node services per VPS deploy memory). Latency target: <2 ms p99 over Unix domain socket. If sidecar is down → model returns `null` (UNKNOWN) and the node logs once-per-minute. Mempool.add MUST NOT block on sidecar response — call is fire-and-forget with a 5 ms timeout, score arrives async via a callback channel.

### 5.2 Why sidecar, not in-process

- **Iteration speed**: retrain weekly without recompiling the Zig node.
- **Isolation**: a buggy model cannot crash the validator.
- **Language fit**: LightGBM, scikit-learn, numpy live happily in Python; embedding LightGBM C runtime in Zig is doable but premature. Revisit after v2 if scoring becomes a hot path.
- **Determinism is not required**: the score is advisory metadata, not consensus state — so we don't need cross-node reproducibility, which would be the only reason to put it in-process.

### 5.3 RPC integration

Add one new method:

```
mempool_anomaly_score(txhash) → { score: float, version: "v1", reasons: [...] }
```

Backed by a `score_cache: HashMap<txhash, score>` in the Zig node, populated when sidecar replies. Hold scores until the TX is mined or evicted — then drop. `reasons` is an optional top-3 SHAP-like feature attribution returned by the sidecar; ignore in v1, plumb in v2.

### 5.4 Model artifact

`models/mempool-anomaly-v1.json` — LightGBM's native JSON dump. Versioned in git (~50-200 KB — acceptable). Bumping the file requires bumping `version` in the RPC response so dashboards can correlate.

### 5.5 What does NOT go in v1

- Auto-quarantine / rate-limit. Score is read-only. Adding actions is a separate proposal — needs governance sign-off because it could accidentally censor legitimate users.
- Cross-node score gossiping. Each node scores independently.
- Online learning. Model is offline-trained, sidecar reload triggered manually.

---

## 6. Effort estimate

| Phase | Work | Hours |
|---|---|---|
| 1 | Feature extractor in Python — replay `omnibus-chain.dat` via existing tooling, emit CSV | 8 |
| 2 | Synthetic anomaly generator (6 classes, parameterized) | 6 |
| 3 | Train + tune LightGBM, cross-validate, calibrate | 6 |
| 4 | Sidecar service (FastAPI + UDS, model load, /score endpoint) | 6 |
| 5 | Zig client glue: `core/mempool_anomaly_client.zig` (UDS POST, 5 ms timeout, async callback, score cache) | 10 |
| 6 | Hook into `Mempool.add` + new RPC method `mempool_anomaly_score` | 4 |
| 7 | Tests (mock sidecar, score-cache eviction, fail-open behavior) | 6 |
| 8 | Operator docs + dashboard panel | 4 |
| **Total** | | **~50 h** |

Add 30% buffer for first-cut iteration → budget **65 h**. Single engineer, two calendar weeks part-time.

---

## 7. Risks

### 7.1 False positives blocking legit users — HIGH severity, MEDIUM likelihood

**Scenario**: a power user batches 30 TXs at 1 SAT/byte (legit) and the model flags as spam. If we ever hook the score to rate-limiting, this user is silently throttled.

**Mitigation**:
- v1 deploys advisory-only (no enforcement). Score visible via RPC but does nothing automatic.
- Calibrate decision threshold on validation set s.t. false-positive rate < 0.1% on real chain TXs.
- Always log score + top-3 features to a TSDB; review weekly before considering enforcement.

### 7.2 Synthetic-vs-real distribution shift — HIGH severity, HIGH likelihood

The synthetic anomaly generator inevitably differs from real attack traffic. The model overfits the generator's idioms.

**Mitigation**: hold out one synthetic class entirely from training each fold (leave-one-attack-out CV). If the model can detect the held-out class, generalization is acceptable. If it can only detect classes it saw, retire that class as an evaluation-only set.

### 7.3 Sidecar latency creep — MEDIUM severity, MEDIUM likelihood

If sidecar latency exceeds 5 ms timeout, the node falls back to UNKNOWN and the score becomes useless.

**Mitigation**: monitor p99 latency, alert on regression. Keep model small (200 trees max). Pre-load on sidecar startup.

### 7.4 Model staleness — MEDIUM severity, HIGH likelihood

Real attack patterns evolve. A model trained on Q1 spam will not catch Q3 spam.

**Mitigation**: weekly retrain pipeline. Monitor feature distribution drift (PSI per feature) — alert if any feature drifts > 0.25 between training set and live traffic.

### 7.5 Adversarial evasion — LOW severity (v1), HIGH likelihood (v2 if we ever enforce)

Once a public RPC exposes the score, attackers can grid-search feature space until they get score < threshold.

**Mitigation**: rate-limit the `mempool_anomaly_score` RPC to 10 req/s per IP. Do NOT publish the model file or feature list externally beyond what's documented here. Plan: switch to randomized-ensemble or noise injection if v2 ever enforces.

### 7.6 Privacy

Feature vectors include sender address velocity. If logged externally (TSDB, dashboard), this is deanonymization-adjacent. Hash addresses with a daily-rotating salt before logging.

---

## 8. Out of scope (explicitly)

- Training the model. (Design only per task.)
- Modifying `core/mempool.zig`. (Design only per task.)
- Building the synthetic generator. (Design only per task.)
- Cross-shard / metachain-aware features. The 4-shard architecture exists but per-shard mempools are independent; per-shard model fine for v1.
- Integration with `omni_brain.zig`. The brain module has bare-metal constraints (Q16.16 fixed-point, no malloc) that fit GBDT inference, but moving inference there is a v3 step taken only after the sidecar approach proves the model's operational value.
