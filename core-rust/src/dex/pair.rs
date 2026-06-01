//! Pair definitions, chain enum, ASSET_CHAINS routing table.
//!
//! Mirrors `core/order_swap_link.zig` (Chain, ASSET_CHAINS, PAIR_ROUTES,
//! htlcContractFor).

use serde::{Deserialize, Serialize};

/// Chain on which an HTLC leg lives.
///
/// `Omnibus` is the home chain (native htlc.zig — pure-Zig HTLC in chain).
/// The rest are EVM chains where the same `OmnibusHTLC.sol` is deployed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum Chain {
    Omnibus = 0,
    Btc = 1,
    Eth = 2,     // Sepolia (11155111)
    Base = 3,    // Base Sepolia (84532)
    Liberty = 4, // LCX Liberty testnet (76847801)
}

impl Chain {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Chain::Omnibus,
            1 => Chain::Btc,
            2 => Chain::Eth,
            3 => Chain::Base,
            4 => Chain::Liberty,
            _ => return None,
        })
    }

    /// EVM chain_id for the EthRef encoding (0 for non-EVM chains).
    pub fn evm_chain_id(self) -> u64 {
        match self {
            Chain::Eth => 11_155_111,
            Chain::Base => 84_532,
            Chain::Liberty => 76_847_801,
            _ => 0,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Chain::Omnibus => "OmniBus",
            Chain::Btc => "Bitcoin",
            Chain::Eth => "Sepolia",
            Chain::Base => "Base Sepolia",
            Chain::Liberty => "LCX Liberty",
        }
    }

    /// HTLC contract address (hex, no 0x prefix) on this chain.
    /// Empty for OmniBus (native htlc in chain) and BTC (P2WSH script).
    pub fn htlc_contract(self) -> &'static str {
        match self {
            Chain::Eth => "270D74dDAccd7a4ABf668DA6F9b238c042353739",
            Chain::Base => "8396666C7345D5AFA4BBcd2Dcea3B6C8B9096eB6",
            Chain::Liberty => "a4ad3f9bA14500F6F1d991b0D8F897E0E8eDEfFb",
            _ => "",
        }
    }
}

// ─── ASSET → chains routing ────────────────────────────────────────────
//
// Each asset can live on multiple chains. Order matters: chains[0] is the
// preferred default. Reflects the canonical Zig ASSET_CHAINS table.

#[derive(Debug, Clone, Copy)]
pub struct AssetChains {
    pub asset: &'static str,
    pub chains: &'static [Chain],
}

const OMNI_CHAINS: &[Chain] = &[Chain::Omnibus];
const LCX_CHAINS: &[Chain] = &[Chain::Liberty];
const ETH_CHAINS: &[Chain] = &[Chain::Eth, Chain::Base]; // Sepolia preferred
const USDC_CHAINS: &[Chain] = &[Chain::Base, Chain::Eth]; // Base preferred (more USDC liquidity)

pub const ASSET_CHAINS: &[AssetChains] = &[
    AssetChains { asset: "OMNI", chains: OMNI_CHAINS },
    AssetChains { asset: "LCX",  chains: LCX_CHAINS  },
    AssetChains { asset: "ETH",  chains: ETH_CHAINS  },
    AssetChains { asset: "USDC", chains: USDC_CHAINS },
];

pub fn chains_for_asset(asset: &str) -> &'static [Chain] {
    for a in ASSET_CHAINS {
        if a.asset == asset {
            return a.chains;
        }
    }
    &[]
}

// ─── Pair definitions ──────────────────────────────────────────────────

/// A trading pair routed by `pair_id`.
///
/// `maker_chains` are the chains on which the maker (base asset seller) can
/// lock funds; `taker_chains` likewise for the taker (quote asset side).
#[derive(Debug, Clone)]
pub struct Pair {
    pub pair_id: u16,
    pub base: &'static str,
    pub quote: &'static str,
    pub maker_chains: &'static [Chain],
    pub taker_chains: &'static [Chain],
}

/// Canonical list of active pairs.
///
/// pair_id 1 (BTC/USDC) and 4 (OMNI/BTC) are RESERVED — not listed.
pub const PAIR_ROUTES: &[Pair] = &[
    Pair {
        pair_id: 0,
        base: "OMNI",
        quote: "USDC",
        maker_chains: OMNI_CHAINS,
        taker_chains: USDC_CHAINS,
    },
    Pair {
        pair_id: 2,
        base: "LCX",
        quote: "USDC",
        maker_chains: LCX_CHAINS,
        taker_chains: USDC_CHAINS,
    },
    Pair {
        pair_id: 3,
        base: "ETH",
        quote: "USDC",
        maker_chains: ETH_CHAINS,
        taker_chains: USDC_CHAINS,
    },
    Pair {
        pair_id: 5,
        base: "OMNI",
        quote: "LCX",
        maker_chains: OMNI_CHAINS,
        taker_chains: LCX_CHAINS,
    },
    Pair {
        pair_id: 6,
        base: "OMNI",
        quote: "ETH",
        maker_chains: OMNI_CHAINS,
        taker_chains: ETH_CHAINS,
    },
];

pub fn pair_route(pair_id: u16) -> Option<&'static Pair> {
    PAIR_ROUTES.iter().find(|p| p.pair_id == pair_id)
}

/// Returns true for pair_ids reserved for future use (must be rejected by
/// place_order). Currently 1 (BTC/USDC) and 4 (OMNI/BTC).
pub fn is_reserved_pair(pair_id: u16) -> bool {
    matches!(pair_id, 1 | 4)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pair_routes_have_expected_ids() {
        let ids: Vec<u16> = PAIR_ROUTES.iter().map(|p| p.pair_id).collect();
        assert_eq!(ids, vec![0, 2, 3, 5, 6]);
    }

    #[test]
    fn reserved_pairs_rejected() {
        assert!(is_reserved_pair(1));
        assert!(is_reserved_pair(4));
        assert!(!is_reserved_pair(0));
        assert!(!is_reserved_pair(5));
    }

    #[test]
    fn omni_pairs_make_on_omnibus() {
        for &pid in &[0u16, 5, 6] {
            let p = pair_route(pid).unwrap();
            assert_eq!(p.maker_chains[0], Chain::Omnibus);
        }
    }

    #[test]
    fn chains_for_asset_lookup() {
        assert_eq!(chains_for_asset("OMNI"), &[Chain::Omnibus]);
        assert_eq!(chains_for_asset("USDC")[0], Chain::Base);
        assert_eq!(chains_for_asset("nope"), &[]);
    }
}
