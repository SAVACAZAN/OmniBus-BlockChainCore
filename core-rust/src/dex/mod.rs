//! OmniBus DEX layer — ported from Zig (`core/matching_engine.zig`,
//! `order_swap_link.zig`, `grid_engine.zig`, `price_oracle.zig`).
//!
//! Architecture (AUTHORITATIVE — see BlockChainCore CLAUDE.md "DEX Grid
//! Trading"):
//!   - OmniBus chain = matching engine + notary; NEVER custodies user funds.
//!   - Funds stay in the user's wallet until a fill happens.
//!   - At fill time: HTLC is born, preimage is generated server-side
//!     (NEVER revealed to the user — user only sees `hash_lock`),
//!     settlement is atomic cross-chain.
//!   - Grid trading: N virtual buy + N virtual sell orders are placed in
//!     [price_low, price_high]; on fill, an opposite order is auto-placed.
//!
//! Fixed pair IDs (never reorder):
//!   pair_id 0 → OMNI/USDC  (OmniBus maker, Base/Sepolia takers)
//!   pair_id 1 → RESERVED (BTC/USDC future)
//!   pair_id 2 → LCX/USDC   (LCX Liberty maker, Base/Sepolia takers)
//!   pair_id 3 → ETH/USDC   (Sepolia/Base maker, Base/Sepolia takers)
//!   pair_id 4 → RESERVED (OMNI/BTC future)
//!   pair_id 5 → OMNI/LCX   (OmniBus maker, LCX Liberty takers)
//!   pair_id 6 → OMNI/ETH   (OmniBus maker, Sepolia/Base takers)

pub mod oracle_types;
pub mod pair;
pub mod order;
pub mod matching;
pub mod matching_engine;
pub mod htlc;
pub mod htlc_native;
pub mod htlc_persist;
pub mod grid;
pub mod grid_engine;
pub mod oracle;
pub mod oracle_main;
pub mod oracle_policy;
pub mod order_swap_link;
pub mod price_oracle;
pub mod fills_log;
pub mod intent_registry;
pub mod orderbook_sync;
pub mod oracle_fetcher;
pub mod pair_registry;
pub mod token_whitelist;
pub mod evm_rpc;
pub mod evm_signer;
pub mod settler;

