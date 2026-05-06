"""Periodicity scan — look for repeating sub-strings in the byte stream.
A good random source has no detectable periodicity at any window size."""
from __future__ import annotations


def find_repeats(data: bytes, window: int = 4, max_scan: int = 100_000) -> dict:
    """Slide a window across data and count how many positions have a duplicate
    elsewhere. For random data, expected duplicates ≈ n^2 / 2^(8*window)."""
    if len(data) < 2 * window:
        return {"window": window, "duplicates": 0, "expected": 0.0, "ratio": 1.0}

    scan = data[:max_scan]
    seen: dict[bytes, int] = {}
    duplicates = 0
    for i in range(len(scan) - window + 1):
        chunk = scan[i:i + window]
        if chunk in seen:
            duplicates += 1
        else:
            seen[chunk] = i

    n = len(scan) - window + 1
    expected = n * n / (2 ** (8 * window) * 2)  # birthday approx
    ratio = duplicates / expected if expected > 0.01 else 0.0
    return {
        "window": window,
        "duplicates": duplicates,
        "expected": expected,
        "ratio": ratio,
        "scanned_bytes": len(scan),
    }


def verdict(stats: dict) -> tuple[str, str]:
    """ratio < 5 = ok (within reasonable factor of expected birthday count)."""
    r = stats.get("ratio", 0.0)
    if r < 2.0:
        return ("[PASS]", "NO_PERIODICITY")
    if r < 5.0:
        return ("[OK]", "ACCEPTABLE")
    if r < 20.0:
        return ("[WARN]", "ELEVATED")
    return ("[FAIL]", "PERIODIC")
