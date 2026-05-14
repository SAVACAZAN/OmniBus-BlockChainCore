/**
 * chains.ts — single source of truth for ALL chains the OmniBus ecosystem
 * touches (bridge destinations, exchange taker chains, HTLC contract
 * addresses, BIP-44 SLIP-44 coin_type, family classification, address
 * validation regex, explorer URL).
 *
 * Background — before this file, frontend had 4+ fragmented chain configs:
 *   - bridge/BridgePage.tsx DEST_CHAINS    (2 chains)
 *   - exchange/PlaceOrderForm TAKER_CHAINS (6 chains per token, repeated)
 *   - api/htlc-eth.ts HTLC_CONTRACTS       (6 chain IDs with placeholders)
 *   - exchange/AmmOrderbookPanel CHAINS    (1 chain)
 * Users saw "2-3 chains" on Bridge while the wallet derived 19 multi-chain
 * keys per memory/project_omnibus_5_isolated_wallets.md. This file is the
 * canonical list. Add new chains HERE; consumers import.
 *
 * Backend side: tx_payload.zig stores dest_chain_id as u16 with no
 * hardcoded enum — any chain in this file is accepted by the chain as long
 * as the bridge module has a corresponding settlement path. The `enabled`
 * flag controls UI visibility; disabled rows are shown grayed-out so users
 * see what's coming.
 *
 * SLIP-44 coin_type column lets wallet/bip32_wallet.zig derive addresses
 * deterministically from the single user mnemonic.
 */

export type ChainFamily =
  | "OmniBus"   // ob1q.../ob_k1_.../ob_f5_... etc.
  | "EVM"       // 0x... (Ethereum & all EVM L1/L2)
  | "Bitcoin"   // bc1... / 1... / 3... (BTC, LTC, DOGE)
  | "Solana"    // base58 (no 0/O/I/l)
  | "Cardano"   // addr1...
  | "Polkadot"  // SS58
  | "Cosmos"    // cosmos1... (bech32 cosmos hub)
  | "NEAR"      // .near or 64-hex
  | "Zilliqa"   // zil1... (bech32)
  | "Algorand"  // base32 58-char
  | "Stellar"   // G... base32
  | "XRP"       // r... base58
  | "MultiversX"; // erd1...

export type ChainEntry = {
  /** Stable string id used by Bridge / Order UI. */
  id: string;
  /** Human-readable label shown in dropdowns. */
  label: string;
  /** Address family — drives which address scheme + regex applies. */
  family: ChainFamily;
  /** EVM chainId (CAIP-2 numeric). 0 for non-EVM chains. */
  chainId: number;
  /** BIP-44 SLIP-44 coin_type for wallet derivation. */
  coinType: number;
  /** Native asset symbol shown in UI. */
  symbol: string;
  /** Public JSON-RPC URL for direct calls (Bridge, AMM panel). null = none. */
  rpc: string | null;
  /** Block explorer base URL — append tx hash. null = no explorer. */
  explorerTx: string | null;
  /** Placeholder shown in address input field. */
  placeholder: string;
  /** Regex that validates a destination address on this chain. */
  addrPattern: RegExp;
  /** HTLC contract address on this chain (EVM only). Empty for non-EVM
      or undeployed; the contract address registry below resolves it. */
  htlcContract?: string;
  /** OmnibusDEX (escrow) contract address on this chain. Used by the
      Buy flow on the native DEX — empty until deployed. */
  dexContract?: string;
  /** Tailwind text color for visual accent. */
  color: string;
  /** Is the bridge/swap path live for this chain? false = "coming soon". */
  enabled: boolean;
  /** Is this a testnet/devnet variant? */
  testnet?: boolean;
};

// ───────────────────────────────────────────────────────────────────────────
// THE MASTER LIST
//
// Order: OmniBus-native first, then EVM L1/L2 (mainnets, then testnets),
// then Bitcoin family, then non-EVM L1s. This is also the display order in
// dropdowns.
//
// To enable a new chain:
//   1. Set `enabled: true`
//   2. If EVM and you have an HTLC contract deployed, set `htlcContract`
//   3. Verify the rpc URL responds
//   4. Test address regex against a real recipient
// ───────────────────────────────────────────────────────────────────────────

export const CHAINS: readonly ChainEntry[] = [
  // ── OmniBus native ───────────────────────────────────────────────────────
  {
    id: "omnibus_mainnet",  label: "OmniBus Mainnet",  family: "OmniBus",
    chainId: 777, coinType: 777, symbol: "OMNI",
    rpc: "http://127.0.0.1:8332",
    explorerTx: null,
    placeholder: "ob1q…",
    addrPattern: /^ob1q[ac-hj-np-z02-9]{38,}$/,
    color: "text-mempool-green", enabled: true,
  },
  {
    id: "omnibus_testnet", label: "OmniBus Testnet", family: "OmniBus",
    chainId: 778, coinType: 777, symbol: "OMNI",
    rpc: "http://127.0.0.1:18332",
    explorerTx: null,
    placeholder: "ob1q… (testnet)",
    addrPattern: /^ob1q[ac-hj-np-z02-9]{38,}$/,
    color: "text-mempool-green/70", enabled: true, testnet: true,
  },
  {
    id: "liberty", label: "LCX Liberty", family: "EVM",
    chainId: 76847801, coinType: 60, symbol: "LCX",
    rpc: "https://rpc.testnet.lcx.com",
    explorerTx: null,
    placeholder: "lib1q… (bech32)",
    addrPattern: /^lib1[a-z0-9]{38,}$/,
    color: "text-purple-400", enabled: true, testnet: true,
  },

  // ── EVM mainnets ─────────────────────────────────────────────────────────
  {
    id: "eth_mainnet", label: "Ethereum Mainnet", family: "EVM",
    chainId: 1, coinType: 60, symbol: "ETH",
    rpc: "https://eth.drpc.org",
    explorerTx: "https://etherscan.io/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    htlcContract: "",
    color: "text-blue-400", enabled: false,
  },
  {
    id: "base", label: "Base (Ethereum L2)", family: "EVM",
    chainId: 8453, coinType: 60, symbol: "ETH",
    rpc: "https://mainnet.base.org",
    explorerTx: "https://basescan.org/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    htlcContract: "",
    color: "text-blue-500", enabled: false,
  },
  {
    id: "bnb", label: "BNB Smart Chain", family: "EVM",
    chainId: 56, coinType: 714, symbol: "BNB",
    rpc: "https://bsc-dataseed.binance.org",
    explorerTx: "https://bscscan.com/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-yellow-400", enabled: false,
  },
  {
    id: "matic", label: "Polygon (PoS)", family: "EVM",
    chainId: 137, coinType: 966, symbol: "MATIC",
    rpc: "https://polygon-rpc.com",
    explorerTx: "https://polygonscan.com/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-purple-500", enabled: false,
  },
  {
    id: "avax", label: "Avalanche C-Chain", family: "EVM",
    chainId: 43114, coinType: 9005, symbol: "AVAX",
    rpc: "https://api.avax.network/ext/bc/C/rpc",
    explorerTx: "https://snowtrace.io/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-red-400", enabled: false,
  },
  {
    id: "ftm", label: "Fantom Opera", family: "EVM",
    chainId: 250, coinType: 1007, symbol: "FTM",
    rpc: "https://rpc.ftm.tools",
    explorerTx: "https://ftmscan.com/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-blue-500", enabled: false,
  },
  {
    id: "one", label: "Harmony ONE", family: "EVM",
    chainId: 1666600000, coinType: 1023, symbol: "ONE",
    rpc: "https://api.harmony.one",
    explorerTx: "https://explorer.harmony.one/tx/",
    placeholder: "0x… or one1…",
    addrPattern: /^(0x[0-9a-fA-F]{40}|one1[a-z0-9]{38})$/,
    color: "text-cyan-400", enabled: false,
  },

  // ── EVM testnets ─────────────────────────────────────────────────────────
  {
    id: "sepolia", label: "Sepolia (ETH testnet)", family: "EVM",
    chainId: 11155111, coinType: 60, symbol: "ETH",
    rpc: "https://sepolia.drpc.org",
    explorerTx: "https://sepolia.etherscan.io/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    htlcContract: "0xC95cAED3179B8D2899acAC193411CC65759cEC81",
    color: "text-blue-300", enabled: true, testnet: true,
  },
  {
    id: "base_sepolia", label: "Base Sepolia", family: "EVM",
    chainId: 84532, coinType: 60, symbol: "ETH",
    rpc: "https://sepolia.base.org",
    explorerTx: "https://sepolia.basescan.org/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    htlcContract: "",
    color: "text-blue-400/70", enabled: false, testnet: true,
  },
  {
    id: "arb_sepolia", label: "Arbitrum Sepolia", family: "EVM",
    chainId: 421614, coinType: 60, symbol: "ETH",
    rpc: "https://sepolia-rollup.arbitrum.io/rpc",
    explorerTx: "https://sepolia.arbiscan.io/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-blue-400/70", enabled: false, testnet: true,
  },
  {
    id: "op_sepolia", label: "OP Sepolia", family: "EVM",
    chainId: 11155420, coinType: 60, symbol: "ETH",
    rpc: "https://sepolia.optimism.io",
    explorerTx: "https://sepolia-optimism.etherscan.io/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-red-400/70", enabled: false, testnet: true,
  },
  {
    id: "polygon_amoy", label: "Polygon Amoy", family: "EVM",
    chainId: 80002, coinType: 966, symbol: "MATIC",
    rpc: "https://rpc-amoy.polygon.technology",
    explorerTx: "https://amoy.polygonscan.com/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-purple-500/70", enabled: false, testnet: true,
  },
  {
    id: "avax_fuji", label: "Avalanche Fuji", family: "EVM",
    chainId: 43113, coinType: 9005, symbol: "AVAX",
    rpc: "https://api.avax-test.network/ext/bc/C/rpc",
    explorerTx: "https://testnet.snowtrace.io/tx/",
    placeholder: "0x… (40-char hex)",
    addrPattern: /^0x[0-9a-fA-F]{40}$/,
    color: "text-red-400/70", enabled: false, testnet: true,
  },

  // ── Bitcoin family ───────────────────────────────────────────────────────
  {
    id: "btc", label: "Bitcoin", family: "Bitcoin",
    chainId: 0, coinType: 0, symbol: "BTC",
    rpc: null,
    explorerTx: "https://mempool.space/tx/",
    placeholder: "bc1q… / 1… / 3…",
    addrPattern: /^(bc1|[13])[a-zA-HJ-NP-Z0-9]{25,90}$/,
    color: "text-orange-400", enabled: false,
  },
  {
    id: "ltc", label: "Litecoin", family: "Bitcoin",
    chainId: 0, coinType: 2, symbol: "LTC",
    rpc: null,
    explorerTx: "https://litecoinspace.org/tx/",
    placeholder: "ltc1… / L… / M…",
    addrPattern: /^(ltc1|[LM3])[a-zA-HJ-NP-Z0-9]{25,90}$/,
    color: "text-gray-300", enabled: false,
  },
  {
    id: "doge", label: "Dogecoin", family: "Bitcoin",
    chainId: 0, coinType: 3, symbol: "DOGE",
    rpc: null,
    explorerTx: "https://dogechain.info/tx/",
    placeholder: "D… (P2PKH)",
    addrPattern: /^D[5-9A-HJ-NP-U][1-9A-HJ-NP-Za-km-z]{32}$/,
    color: "text-yellow-300", enabled: false,
  },

  // ── Non-EVM L1s ──────────────────────────────────────────────────────────
  {
    id: "sol", label: "Solana", family: "Solana",
    chainId: 0, coinType: 501, symbol: "SOL",
    rpc: "https://api.mainnet-beta.solana.com",
    explorerTx: "https://solscan.io/tx/",
    placeholder: "Solana base58",
    addrPattern: /^[1-9A-HJ-NP-Za-km-z]{32,44}$/,
    color: "text-green-400", enabled: false,
  },
  {
    id: "ada", label: "Cardano", family: "Cardano",
    chainId: 0, coinType: 1815, symbol: "ADA",
    rpc: null,
    explorerTx: "https://cardanoscan.io/transaction/",
    placeholder: "addr1…",
    addrPattern: /^addr1[a-z0-9]{50,}$/,
    color: "text-blue-600", enabled: false,
  },
  {
    id: "dot", label: "Polkadot", family: "Polkadot",
    chainId: 0, coinType: 354, symbol: "DOT",
    rpc: null,
    explorerTx: "https://polkadot.subscan.io/extrinsic/",
    placeholder: "1… (SS58)",
    addrPattern: /^[1-9A-HJ-NP-Za-km-z]{47,48}$/,
    color: "text-pink-400", enabled: false,
  },
  {
    id: "atom", label: "Cosmos Hub", family: "Cosmos",
    chainId: 0, coinType: 118, symbol: "ATOM",
    rpc: null,
    explorerTx: "https://mintscan.io/cosmos/txs/",
    placeholder: "cosmos1…",
    addrPattern: /^cosmos1[a-z0-9]{38}$/,
    color: "text-cyan-300", enabled: false,
  },
  {
    id: "near", label: "NEAR", family: "NEAR",
    chainId: 0, coinType: 397, symbol: "NEAR",
    rpc: "https://rpc.mainnet.near.org",
    explorerTx: "https://nearblocks.io/txns/",
    placeholder: "name.near or 64-hex",
    addrPattern: /^([a-z0-9_\-\.]{2,64}\.near|[a-f0-9]{64})$/,
    color: "text-green-300", enabled: false,
  },
  {
    id: "zil", label: "Zilliqa", family: "Zilliqa",
    chainId: 0, coinType: 313, symbol: "ZIL",
    rpc: null,
    explorerTx: "https://viewblock.io/zilliqa/tx/",
    placeholder: "zil1…",
    addrPattern: /^zil1[a-z0-9]{38}$/,
    color: "text-teal-400", enabled: false,
  },
  {
    id: "algo", label: "Algorand", family: "Algorand",
    chainId: 0, coinType: 283, symbol: "ALGO",
    rpc: null,
    explorerTx: "https://allo.info/tx/",
    placeholder: "Algorand base32 (58 chars)",
    addrPattern: /^[A-Z2-7]{58}$/,
    color: "text-emerald-400", enabled: false,
  },
  {
    id: "xlm", label: "Stellar", family: "Stellar",
    chainId: 0, coinType: 148, symbol: "XLM",
    rpc: null,
    explorerTx: "https://stellar.expert/explorer/public/tx/",
    placeholder: "G… (Stellar)",
    addrPattern: /^G[A-Z2-7]{55}$/,
    color: "text-amber-300", enabled: false,
  },
  {
    id: "xrp", label: "XRP Ledger", family: "XRP",
    chainId: 0, coinType: 144, symbol: "XRP",
    rpc: null,
    explorerTx: "https://xrpscan.com/tx/",
    placeholder: "r… (XRP)",
    addrPattern: /^r[1-9A-HJ-NP-Za-km-z]{24,34}$/,
    color: "text-sky-400", enabled: false,
  },
  {
    id: "egld", label: "MultiversX (EGLD)", family: "MultiversX",
    chainId: 0, coinType: 508, symbol: "EGLD",
    rpc: "https://api.multiversx.com",
    explorerTx: "https://explorer.multiversx.com/transactions/",
    placeholder: "erd1…",
    addrPattern: /^erd1[a-z0-9]{58}$/,
    color: "text-violet-400", enabled: false,
  },
] as const;

// ───────────────────────────────────────────────────────────────────────────
// Helpers
// ───────────────────────────────────────────────────────────────────────────

/** Lookup by id. Returns null if unknown. */
export function findChain(id: string): ChainEntry | null {
  return CHAINS.find((c) => c.id === id) ?? null;
}

/** Lookup by EVM chainId. Skips non-EVM entries (chainId=0). */
export function findChainByEvmId(chainId: number): ChainEntry | null {
  if (chainId === 0) return null;
  return CHAINS.find((c) => c.chainId === chainId) ?? null;
}

/** Lookup HTLC contract address by chainId. Empty string = undeployed. */
export function htlcContractFor(chainId: number): string {
  return findChainByEvmId(chainId)?.htlcContract ?? "";
}

/** Filter chains by family. */
export function chainsByFamily(family: ChainFamily): ChainEntry[] {
  return CHAINS.filter((c) => c.family === family);
}

/** Only enabled (live) chains — use for dropdowns where order can actually
    settle right now. */
export function enabledChains(): ChainEntry[] {
  return CHAINS.filter((c) => c.enabled);
}

/** Disabled / coming-soon chains — render grayed-out in pickers. */
export function disabledChains(): ChainEntry[] {
  return CHAINS.filter((c) => !c.enabled);
}

/** EVM chains only (for HTLC, MetaMask switching, etc.). */
export function evmChains(): ChainEntry[] {
  return chainsByFamily("EVM");
}

/** Validate an address against a chain's pattern. */
export function isValidAddress(chainId: string, address: string): boolean {
  const c = findChain(chainId);
  if (!c) return false;
  return c.addrPattern.test(address);
}

/** Build full explorer URL or return null if chain has no explorer. */
export function explorerLink(chainId: string, txHash: string): string | null {
  const c = findChain(chainId);
  if (!c?.explorerTx) return null;
  return c.explorerTx + txHash;
}

/** Count by status — useful for dashboards. */
export function chainCounts(): { total: number; enabled: number; disabled: number; testnets: number } {
  let enabledN = 0;
  let testnetsN = 0;
  for (const c of CHAINS) {
    if (c.enabled) enabledN += 1;
    if (c.testnet) testnetsN += 1;
  }
  return {
    total: CHAINS.length,
    enabled: enabledN,
    disabled: CHAINS.length - enabledN,
    testnets: testnetsN,
  };
}
