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

pub mod pair;
pub mod order;
pub mod matching;
pub mod htlc;
pub mod grid;
pub mod oracle;

pub use pair::{Chain, Pair, pair_route, PAIR_ROUTES, ASSET_CHAINS, chains_for_asset};
pub use order::{Order, OrderId, OrderStatus, Side};
pub use matching::{Fill, MatchingEngine, MatchingError};
pub use htlc::{HtlcError, HtlcState, SwapBinding, SwapRegistry};
pub use grid::{GridConfig, GridError, GridRegistry, TickResult};
pub use oracle::{OracleError, PriceOracle};
