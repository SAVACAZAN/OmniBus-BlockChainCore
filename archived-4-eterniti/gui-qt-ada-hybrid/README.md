# OmniBus Qt+Ada Hybrid GUI

**Qt6 C++ GUI** + **Ada SPARK vault library** (.dll)

Best of both worlds:
- **Qt6**: Battle-tested GUI framework, native Windows look, DPI scaling, hardware rendering
- **Ada SPARK**: Mathematically proven vault crypto (DPAPI encrypt/decrypt, secure wipe)

## Architecture

```
omnibus-qt-ada.exe  (Qt6 C++)
    │
    ├── RPC Client ─────→ Zig blockchain node (port 8332)
    ├── WebSocket ──────→ Push events (port 8334)
    │
    └── AdaVaultBridge ─→ omnibus_vault.dll (Ada SPARK)
                              │
                              ├── DPAPI Encrypt/Decrypt (SPARK verified)
                              ├── Secure Memory Wipe   (SPARK proven)
                              ├── Exchange Key Storage  (SPARK contracts)
                              └── Binary vault format v4 (SuperVault compatible)
```

## Build

```bash
build.bat
```

Requires:
- Qt6 (with cmake integration)
- GNAT (Ada compiler, via Alire)
- CMake 3.21+ and Ninja

## Security

The Ada SPARK vault library provides:
- **Pre/Post conditions** on every function (verified at compile time)
- **DPAPI encryption** tied to Windows user account
- **Secure wipe** guaranteed not optimized away (SPARK postcondition)
- **No heap allocation** in crypto paths
- Same binary vault format as OmnibusSidebar SuperVault (OMNV v4)
