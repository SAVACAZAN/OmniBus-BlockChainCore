# `core/` — Zig blockchain node (canonical impl)

This directory is the **Zig** sibling implementation of the OmniBus node.
The Rust sibling lives at [`../core-rust/`](../core-rust/), and an
exploratory C++ tree at [`../core-cpp/`](../core-cpp/).

Both Zig and Rust impls peer over the same P2P protocol (like `reth ↔ geth`)
and must produce byte-identical block hashes, serialization, genesis state,
PoW results, and PQ signature verification. Where they diverge, the Zig
impl is **canonical** — the Rust port chases the Zig source.

## Why isn't this named `core-zig/`?

For legacy reasons. The rename was considered in 2026-06-02 but rejected:
~600 references (in `build.zig`, Rust doc-comments, VPS systemd units,
Gitea Actions, deploy scripts) would need updating, with non-zero risk of
breaking out-of-repo infrastructure. The disambiguation cost outweighs
the benefit when this file already names it.

## Layout

See `../README.md` (top-level) for the module map. Inside this directory:

- `main.zig` — node entry point
- `rpc_server.zig` — JSON-RPC 2.0 (port 8332/18332/28332)
- `blockchain.zig`, `block.zig`, `transaction.zig` — chain state + TX/block
- `wallet/`, `consensus/`, `dex/`, `bridge/`, `mining/`, `agents/`, … —
  subsystems, see each subdir for its own README where present

## Build

```sh
# From repo root, not from this directory.
zig build -Doptimize=ReleaseSafe -Doqs=true
```

See top-level `README.md` for the full quick-start.
