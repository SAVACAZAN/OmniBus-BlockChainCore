//! bridge — cross-chain settlement infrastructure.
//!
//! Houses the EVM-side glue (signer, RPC client, escrow watcher) and the
//! cross-chain oracle / escrow primitives. The settler bot itself
//! (`dex_settler`, `settlement_submitter`) plus the BTC HTLC settler
//! (`htlc_btc`) and the native L1↔L2 bridge daemons (`bridge_native`,
//! `bridge_relay`, `bridge_listener`) are tracked here as `pub mod`
//! skeleton stubs — they sit on >2k LoC of orchestration each and depend
//! on yet-unported subsystems (validator/staking, signed_attestations,
//! treasury wallet, BTC SPV) that other agents own.
//!
//! Cross-references:
//!   - parity audit: `1_CORE/BlockChainCore/PARITY_AUDIT_zig_vs_rust_2026-06-02.md`
//!   - Zig sources: `1_CORE/BlockChainCore/core/`
//!
//! Ported from core/*.zig (2026-06-02).

pub mod chain_rpc_client;
pub mod cross_chain_oracle;
pub mod escrow;
pub mod evm_escrow_watcher;
pub mod evm_executor;
pub mod evm_rpc_client;
pub mod evm_signer;

// Full ports.
pub mod bridge_listener;
pub mod settlement_submitter;

// Skeleton stubs (waiting on other agents' modules — see file docs).
pub mod dex_settler;

// Native bridge state machine + relay lifecycle daemon.
pub mod bridge_native;
pub mod bridge_relay;

pub use chain_rpc_client::{ChainClient, RpcError as ChainRpcError};
pub use cross_chain_oracle::{BtcAnchor, CrossChainOracle, EthAnchor, OracleError};
pub use escrow::{EscrowEntry, EscrowRegistry, EscrowStatus};
pub use evm_escrow_watcher::{Binding as WatcherBinding, Config as WatcherConfig, EvmEscrow, Watcher};
pub use evm_rpc_client::RpcError as EvmRpcError;
pub use evm_signer::{sign_legacy_tx, SignError, TxInput};
