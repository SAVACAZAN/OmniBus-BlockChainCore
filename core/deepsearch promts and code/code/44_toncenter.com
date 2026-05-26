
---

## 📄 50. `docs/BTC_INTEGRATION.md`

```markdown
# Bitcoin Integration Guide

## Overview

OmniBus wallet supports Bitcoin through:
- Native Segwit (P2WPKH) - bc1q addresses
- Taproot (P2TR) - bc1p addresses
- Legacy (P2PKH) - 1... addresses (limited)

## Address Types

### P2WPKH (Segwit Native)

**Recommended** for most use cases:
- Smaller transaction size
- Lower fees
- Wide wallet support

```zig
const addr = try btc_address.deriveP2WPKHAddress(seed, 0, 0);
// Output: bc1q...