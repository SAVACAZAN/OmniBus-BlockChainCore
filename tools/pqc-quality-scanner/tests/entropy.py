"""Shannon entropy on byte stream — target ≥ 7.95 bits/byte for 256 symbols."""
from __future__ import annotations
import math
from collections import Counter


def shannon_entropy(data: bytes) -> float:
    """Bits per byte. Max = 8.0 (uniform distribution over 256 values)."""
    if not data:
        return 0.0
    counts = Counter(data)
    n = len(data)
    h = 0.0
    for c in counts.values():
        p = c / n
        h -= p * math.log2(p)
    return h


def chi_square_uniformity(data: bytes) -> float:
    """Chi-square statistic vs uniform distribution.
    Lower = more uniform. For 255 dof, p>0.01 ≈ stat < 310."""
    if not data:
        return 0.0
    counts = Counter(data)
    n = len(data)
    expected = n / 256.0
    chi2 = 0.0
    for byte_val in range(256):
        observed = counts.get(byte_val, 0)
        chi2 += (observed - expected) ** 2 / expected
    return chi2


def verdict(entropy: float, chi2: float) -> tuple[str, str]:
    """Return (status_emoji, label)."""
    if entropy >= 7.99 and chi2 < 310.0:
        return ("[PASS]", "EXCELLENT")
    if entropy >= 7.90 and chi2 < 400.0:
        return ("[OK]", "GOOD")
    if entropy >= 7.50:
        return ("[WARN]", "MARGINAL")
    return ("[FAIL]", "POOR")
