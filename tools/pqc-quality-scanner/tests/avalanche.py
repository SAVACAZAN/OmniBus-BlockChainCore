"""Avalanche effect — flip 1 bit in input, count % of output bits that change.
For a good cryptographic primitive, ~50% of output bits flip (strict avalanche)."""
from __future__ import annotations


def hamming_distance_bits(a: bytes, b: bytes) -> int:
    """Count bits that differ between two byte strings of equal length."""
    if len(a) != len(b):
        n = min(len(a), len(b))
        a, b = a[:n], b[:n]
    return sum(bin(x ^ y).count("1") for x, y in zip(a, b))


def avalanche_score(pairs: list[tuple[bytes, bytes]]) -> dict:
    """pairs = list of (sig_msg1, sig_msg2_with_1bit_flip).
    Returns {mean_pct, std_pct, samples}.
    Target: mean ≈ 50% (range 49–51%)."""
    if not pairs:
        return {"mean_pct": 0.0, "std_pct": 0.0, "samples": 0}

    pcts = []
    for sig_a, sig_b in pairs:
        bits_diff = hamming_distance_bits(sig_a, sig_b)
        bits_total = min(len(sig_a), len(sig_b)) * 8
        if bits_total > 0:
            pcts.append(100.0 * bits_diff / bits_total)

    n = len(pcts)
    mean = sum(pcts) / n if n else 0.0
    var = sum((p - mean) ** 2 for p in pcts) / n if n else 0.0
    return {
        "mean_pct": mean,
        "std_pct": var ** 0.5,
        "samples": n,
        "min_pct": min(pcts) if pcts else 0.0,
        "max_pct": max(pcts) if pcts else 0.0,
    }


def verdict(mean_pct: float, std_pct: float) -> tuple[str, str]:
    """Strict avalanche criterion: 49–51% mean, low std."""
    if 49.0 <= mean_pct <= 51.0 and std_pct < 2.0:
        return ("[PASS]", "STRICT_AVALANCHE")
    if 47.0 <= mean_pct <= 53.0 and std_pct < 4.0:
        return ("[OK]", "GOOD")
    if 40.0 <= mean_pct <= 60.0:
        return ("[WARN]", "WEAK")
    return ("[FAIL]", "BIASED")
