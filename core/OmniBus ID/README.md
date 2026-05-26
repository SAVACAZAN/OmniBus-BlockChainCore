# OmniBus ID — moved

The OmniBus ID identity layer has been refactored from the original transcript
dump and now lives under `core/identity/`. This folder is kept as a marker
for audit history; remove it entirely if you don't need the breadcrumb.

## Where things went

| Old (dump)                              | New (live)                                  |
|-----------------------------------------|---------------------------------------------|
| `11_omnibus_did.zig`                    | `core/identity/id_did.zig`                  |
| `12_omnibus_manifest.zig`               | `core/identity/id_manifest.zig`             |
| `13_omnibus_obm.zig`                    | `core/identity/id_obm.zig`                  |
| `14_omnibus_salt_manager.zig`           | `core/identity/id_salt.zig`                 |
| `15_omnibus_selective_disclosure.zig`   | `core/identity/id_disclosure.zig`           |
| `27_omnibus_audit_trail.zig`            | already in `core/audit.zig` — no port      |
| `28_omnibus_mica_compliance.zig`        | `core/identity/id_compliance.zig` (stub)    |
| `29_omnibus_gdpr_proof.zig`             | merged into `id_compliance.zig`             |
| `01_omnibus_types.zig`                  | `core/identity/id_types.zig` (slim)         |
| `16_omnibus_bip32.zig`                  | dropped — chain has `core/bip32_wallet.zig` |
| `17..20_omnibus_*.zig` (BTC/EVM/SOL/PQ) | dropped — chain has these natively          |
| `21..23_omnibus_registry_*.zig`         | dropped — chain has `core/dns_registry.zig` |
| `24..26_*_bridge.zig` (JNI/Swift/WASM)  | deferred to a separate PR                   |
| `04_omnibus_constants.zig`              | dropped — values inlined where used         |

## Run the test suite

```bash
zig build test-id -Doqs=false
```

This is the only step required to verify the identity layer; everything
else (PQ keys, ECDSA wallet, reputation, DNS registry) reuses the live
chain modules and is exercised by their own test suites.
