# /OmniBusBlockChainInventory

Generate a fresh, dynamic inventory of every operation, TX type, address
scheme, RPC method, WebSocket event, and module exposed by the OmniBus
BlockChainCore.

The scanner is purely regex-based over `core/*.zig` — it does NOT need a
build, and **every new file or RPC handler is detected automatically** the
next time you run it.

## What gets counted

- **RPC methods** — dispatcher entries in `core/rpc_server.zig`, classified
  by namespace (Exchange, NS, PQ, Eth-compat, Bridge, …). Stubs returning
  `-32601` are flagged separately.
- **TX types** — entries in the `TxType` enum in `core/transaction.zig`.
- **Address schemes** — entries in the `Scheme` enum (ECDSA, PQ, hybrid).
- **WebSocket events** — `publishEvent("…")` / `broadcastEvent("…")` /
  `"event": "…"` literals in `core/ws_server.zig`.
- **Modules** — every `core/*.zig`, with `pub fn` count and LOC.
- **Unknown namespaces** — methods like `lending_*` or `xyz_*` group
  automatically under `Other (xyz_*)` so future additions surface without
  editing the script.

## Usage

```bash
# Markdown to stdout (quick read)
python tools/inventory-scan.py

# Persist current snapshot
python tools/inventory-scan.py --out STATUS/INVENTORY.md
python tools/inventory-scan.py --json --out STATUS/INVENTORY.json
```

## Steps for Claude when this skill is invoked

1. Run `python tools/inventory-scan.py --out STATUS/INVENTORY.md` from the
   `BlockChainCore/` working directory.
2. Run `python tools/inventory-scan.py --json --out STATUS/INVENTORY.json`
   to refresh the JSON snapshot used by dashboards.
3. Show the user the **top-line counts table** and the **RPC namespaces
   table** from stdout. Skip the long enum dumps unless asked.
4. If new RPC methods landed under `Other (...)`, mention them — that's
   the cue to extend the `NAMESPACES` rules in `tools/inventory-scan.py`
   so the next run categorises them.
5. End with: file paths of the two generated artifacts so the user can
   open them.

## Files

- Scanner:  `tools/inventory-scan.py`
- Outputs:  `STATUS/INVENTORY.md`, `STATUS/INVENTORY.json`