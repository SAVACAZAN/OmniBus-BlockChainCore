"""NIST SP 800-22 statistical test suite — implements 6 of the 15 tests.

References:
- NIST SP 800-22 Rev. 1a, "A Statistical Test Suite for Random and
  Pseudorandom Number Generators for Cryptographic Applications".

Each test returns a p-value. p ≥ 0.01 = pass (sequence not rejected as non-random).

Implemented:
1. Frequency (monobit) test
2. Frequency within blocks
3. Runs test
4. Longest-run-of-ones in a block
5. Serial test (m=2)
6. Approximate entropy test (m=2)
"""
from __future__ import annotations
import math
from typing import List


# ── Helpers ────────────────────────────────────────────────────────────────

def _bytes_to_bits(data: bytes) -> List[int]:
    bits = []
    for byte in data:
        for i in range(7, -1, -1):
            bits.append((byte >> i) & 1)
    return bits


def _erfc(x: float) -> float:
    """Complementary error function — using math.erfc."""
    return math.erfc(x)


def _igamc(a: float, x: float) -> float:
    """Regularized upper incomplete gamma function Q(a, x).
    Used for chi-square p-values."""
    if x < 0 or a <= 0:
        return 1.0
    if x == 0:
        return 1.0
    if x < a + 1:
        # Series representation
        ap = a
        s = 1.0 / a
        delta = s
        for _ in range(200):
            ap += 1
            delta *= x / ap
            s += delta
            if abs(delta) < abs(s) * 1e-12:
                break
        gln = math.lgamma(a)
        return 1.0 - s * math.exp(-x + a * math.log(x) - gln)
    else:
        # Continued fraction
        b = x + 1.0 - a
        c = 1e30
        d = 1.0 / b
        h = d
        for i in range(1, 200):
            an = -i * (i - a)
            b += 2.0
            d = an * d + b
            if abs(d) < 1e-30:
                d = 1e-30
            c = b + an / c
            if abs(c) < 1e-30:
                c = 1e-30
            d = 1.0 / d
            delt = d * c
            h *= delt
            if abs(delt - 1.0) < 1e-12:
                break
        gln = math.lgamma(a)
        return h * math.exp(-x + a * math.log(x) - gln)


# ── Tests ──────────────────────────────────────────────────────────────────

def frequency_monobit(data: bytes) -> float:
    """Test 1: Sum of (2*bit-1). p = erfc(|S|/sqrt(2n))."""
    bits = _bytes_to_bits(data)
    n = len(bits)
    if n < 100:
        return 0.0
    s = sum(2 * b - 1 for b in bits)
    return _erfc(abs(s) / math.sqrt(2.0 * n))


def frequency_block(data: bytes, block_size: int = 128) -> float:
    """Test 2: Chi-square on block frequencies."""
    bits = _bytes_to_bits(data)
    n = len(bits)
    if n < block_size:
        return 0.0
    num_blocks = n // block_size
    chi2 = 0.0
    for i in range(num_blocks):
        block = bits[i * block_size:(i + 1) * block_size]
        pi = sum(block) / block_size
        chi2 += (pi - 0.5) ** 2
    chi2 *= 4.0 * block_size
    return _igamc(num_blocks / 2.0, chi2 / 2.0)


def runs_test(data: bytes) -> float:
    """Test 3: Number of runs (uninterrupted same-bit sequences)."""
    bits = _bytes_to_bits(data)
    n = len(bits)
    if n < 100:
        return 0.0
    pi = sum(bits) / n
    if abs(pi - 0.5) > 2.0 / math.sqrt(n):
        return 0.0
    runs = 1
    for i in range(1, n):
        if bits[i] != bits[i - 1]:
            runs += 1
    num = abs(runs - 2 * n * pi * (1 - pi))
    den = 2 * math.sqrt(2 * n) * pi * (1 - pi)
    if den == 0:
        return 0.0
    return _erfc(num / den)


def longest_run_of_ones(data: bytes) -> float:
    """Test 4: Longest run of 1s in M-bit blocks (n ≥ 128)."""
    bits = _bytes_to_bits(data)
    n = len(bits)
    # NIST minimum: 128 bits (M=8) — use that for our typical sig sizes
    M = 8
    K = 3
    pi = [0.21484375, 0.3671875, 0.23046875, 0.1875]
    if n < 128:
        return 0.0
    num_blocks = n // M
    if num_blocks < 16:
        # NIST recommends ≥ 16 blocks for stability
        return 0.0

    counts = [0] * (K + 1)
    for i in range(num_blocks):
        block = bits[i * M:(i + 1) * M]
        max_run = 0
        cur = 0
        for b in block:
            if b == 1:
                cur += 1
                max_run = max(max_run, cur)
            else:
                cur = 0
        if max_run <= 1:
            counts[0] += 1
        elif max_run == 2:
            counts[1] += 1
        elif max_run == 3:
            counts[2] += 1
        else:
            counts[3] += 1

    chi2 = 0.0
    for i in range(K + 1):
        expected = num_blocks * pi[i]
        if expected > 0:
            chi2 += (counts[i] - expected) ** 2 / expected
    return _igamc(K / 2.0, chi2 / 2.0)


def serial_test(data: bytes, m: int = 2) -> float:
    """Test 5: Frequency of all m-bit patterns. Returns p-value of psi^2_m."""
    bits = _bytes_to_bits(data)
    n = len(bits)
    if n < (m + 2) ** 2:
        return 0.0

    def psi_sq(mm: int) -> float:
        if mm == 0:
            return 0.0
        ext = bits + bits[:mm - 1]
        counts: dict = {}
        for i in range(n):
            pattern = tuple(ext[i:i + mm])
            counts[pattern] = counts.get(pattern, 0) + 1
        s = sum(c * c for c in counts.values())
        return (2 ** mm / n) * s - n

    psi_m = psi_sq(m)
    psi_m1 = psi_sq(m - 1)
    delta = psi_m - psi_m1
    df = 2 ** (m - 1)
    return _igamc(df / 2.0, delta / 2.0)


def approximate_entropy(data: bytes, m: int = 2) -> float:
    """Test 6: Approximate entropy compares pattern frequencies for m vs m+1."""
    bits = _bytes_to_bits(data)
    n = len(bits)
    if n < 64:
        return 0.0

    def phi(mm: int) -> float:
        ext = bits + bits[:mm - 1] if mm > 0 else bits
        counts: dict = {}
        for i in range(n):
            pattern = tuple(ext[i:i + mm])
            counts[pattern] = counts.get(pattern, 0) + 1
        s = 0.0
        for c in counts.values():
            p = c / n
            if p > 0:
                s += p * math.log(p)
        return s

    apen = phi(m) - phi(m + 1)
    chi2 = 2.0 * n * (math.log(2) - apen)
    df = 2 ** m
    return _igamc(df / 2.0, chi2 / 2.0)


# ── Aggregate ──────────────────────────────────────────────────────────────

def run_all(data: bytes) -> dict:
    """Run all 6 tests, return p-values + pass count."""
    tests = {
        "frequency_monobit":   frequency_monobit(data),
        "frequency_block":     frequency_block(data),
        "runs":                runs_test(data),
        "longest_run_of_ones": longest_run_of_ones(data),
        "serial":              serial_test(data, m=2),
        "approximate_entropy": approximate_entropy(data, m=2),
    }
    passed = sum(1 for p in tests.values() if p >= 0.01)
    return {
        "p_values": tests,
        "passed": passed,
        "total": len(tests),
    }


def verdict(result: dict) -> tuple[str, str]:
    p = result.get("passed", 0)
    t = result.get("total", 6)
    if p == t:
        return ("[PASS]", f"NIST {p}/{t}")
    if p >= t - 1:
        return ("[OK]", f"NIST {p}/{t}")
    if p >= t // 2:
        return ("[WARN]", f"NIST {p}/{t}")
    return ("[FAIL]", f"NIST {p}/{t}")
