# PQC Quality Scanner

Standalone tool that runs **statistical quality tests** on the post-quantum
algorithms used by OmniBus. **Not part of the chain** — it lives next to it
in `tools/`. The chain is the source of truth for which algorithms are
canonical; this tool is the proof those algorithms produce well-distributed,
non-periodic, high-entropy output.

## What it tests

| Test | What it measures | Pass threshold |
|---|---|---|
| **Shannon entropy** | Information density of signature bytes | ≥ 7.95 / 8.0 |
| **Avalanche effect** | % of output bits that flip when one input bit flips | 49–51% |
| **Periodicity scan** | Repeating sub-patterns in signature output | none ≥ 4 bytes |
| **NIST SP 800-22 (6/15)** | Frequency, runs, longest-run, FFT, serial, approx-entropy | each p ≥ 0.01 |

These are statistical sanity checks (output looks random), **not** breaks of
the underlying math. A failing score means "this algorithm produces visible
patterns" — never "key recovered".

## Algorithms tested (canonical OmniBus set)

| ID | NIST | Library |
|---|---|---|
| ML-DSA-87 | FIPS 204 | @noble/post-quantum (real) |
| Falcon-512 | FIPS 206 | @noble/post-quantum (real) |
| Dilithium-5 | FIPS 204 alias | @noble/post-quantum (ml_dsa87) |
| SLH-DSA-256s | FIPS 205 | @noble/post-quantum (real) |
| AES-256-CTR | FIPS 197 | reference baseline (well-known good) |
| XOR-weak | — | reference baseline (well-known bad) |

Add new algorithms by writing an adapter in `algorithms/` that produces
`(public_key_bytes, signature_bytes)` per message — see `algorithms/liboqs_adapter.py`.

## Usage

```bash
cd 1_CORE/BlockChainCore/tools/pqc-quality-scanner

# 1. Generate signatures from JS (uses @noble/post-quantum from frontend)
python run.py --generate

# 2. Run all statistical tests on cached signatures
python run.py --scan

# 3. Both in one go + report
python run.py --full --report STATUS/PQC_QUALITY_$(date +%F).md
```

Outputs:
- `reports/<algo>_signatures.bin` — N signatures cached for analysis
- `reports/<algo>_metrics.json` — raw test results
- `STATUS/PQC_QUALITY_<date>.md` — human-readable Markdown report

## Why this is separate from the chain

- **Chain** (`core/transaction.zig`) cares only "is this signature valid".
- **Scanner** (this tool) cares "is the signature output statistically
  indistinguishable from random".
- A signature can be valid AND have poor statistical quality (e.g. a custom
  scheme with deterministic bias) — the chain wouldn't notice. This tool will.

## Roadmap (not blocking)

- [ ] Hook to chain RPC `pq_verify_test` to test signatures produced by
      *the chain itself* via liboqs C bindings (currently we test
      @noble/post-quantum which is JS-pure but bit-equivalent).
- [ ] Add the remaining 9 NIST SP 800-22 tests.
- [ ] Add periodicity at byte and bit level.
- [ ] Plot charts (matplotlib) in the Markdown report.
- [ ] CI integration: fail PR if any algorithm scores < 7.99 entropy.
- [ ] Extend to research algorithms (UOV, MAYO, CROSS) — would need a
      dedicated adapter; out of scope for now (chain is FIPS-only).
