/**
 * Live balance fetchers for multichain addresses.
 * Uses public block-explorer APIs — no API keys, browser-side only.
 *
 * Each function returns { native: string, fiat?: string } where `native` is
 * the human-readable balance in the chain's native unit (BTC, ETH, SOL, etc).
 *
 * On failure returns null — caller decides whether to show "?" or retry.
 */

export type ChainBalance = {
  native: string;        // e.g. "0.00012345"
  symbol: string;        // e.g. "BTC", "ETH"
  raw: string;           // raw smallest-unit value as string (sat, wei, lamports)
};

// ── BTC family (BTC / LTC / DOGE / BCH) ──────────────────────────────────────
// All use blockchair as a unified explorer (returns satoshi-equivalent).

async function fetchBlockchairBalance(chain: string, address: string): Promise<ChainBalance | null> {
  try {
    const url = `https://api.blockchair.com/${chain}/dashboards/address/${address}`;
    const r = await fetch(url, { method: "GET" });
    if (!r.ok) return null;
    const j = await r.json();
    const data = j?.data?.[address];
    if (!data) return null;
    const balanceSat: number = data.address?.balance ?? 0;
    const decimals = chain === "dogecoin" ? 8 : 8;
    const native = (balanceSat / Math.pow(10, decimals)).toFixed(8);
    const symbol = chain === "bitcoin" ? "BTC"
      : chain === "litecoin" ? "LTC"
      : chain === "dogecoin" ? "DOGE"
      : chain === "bitcoin-cash" ? "BCH"
      : "?";
    return { native, symbol, raw: String(balanceSat) };
  } catch {
    return null;
  }
}

// ── EVM (ETH + L2s + testnets + Liberty) ─────────────────────────────────────
// RPC URLs from aweb3/src/config/chains.ts (single source of truth).

const EVM_RPC: Record<string, string> = {
  ETH:           "https://eth.llamarpc.com",
  ARBITRUM:      "https://arb1.arbitrum.io/rpc",
  OPTIMISM:      "https://mainnet.optimism.io",
  POLYGON:       "https://polygon-rpc.com",
  BASE:          "https://base.drpc.org",
  BSC:           "https://bsc-dataseed.binance.org",
  AVAX:          "https://api.avax.network/ext/bc/C/rpc",
  SEPOLIA:       "https://sepolia.drpc.org",
  BASE_SEPOLIA:  "https://sepolia.base.org",
  LIBERTY:       "https://testnet-rpc.lcx.com",   // LCX Liberty testnet, chainId 76847801
  // Circle USDC testnet chains
  ARB_SEPOLIA:   "https://sepolia-rollup.arbitrum.io/rpc",
  OP_SEPOLIA:    "https://sepolia.optimism.io",
  POLYGON_AMOY:  "https://rpc-amoy.polygon.technology",
  AVAX_FUJI:     "https://api.avax-test.network/ext/bc/C/rpc",
};

// USDC contract addresses (Circle official only — no bridged variants)
// Mainnet
export const USDC_CONTRACT: Record<string, string> = {
  ETH:           "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  BASE:          "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  ARBITRUM:      "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  POLYGON:       "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
  // Testnets — Circle faucet.circle.com supports all of these
  SEPOLIA:       "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
  BASE_SEPOLIA:  "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
  ARB_SEPOLIA:   "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d",
  OP_SEPOLIA:    "0x5fd84259d66Cd46123540766Be93DFE6D43130D7",
  POLYGON_AMOY:  "0x41e94eb019c0762f9bfcf9fb1e58725bfb0e7582",
  AVAX_FUJI:     "0x5425890298aed601595a70AB815c96711a31Bc65",
};

// EURC — Circle official + Liberty chain
const EURC_CONTRACT: Record<string, string> = {
  ETH:          "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c",
  BASE:         "0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42",
  SEPOLIA:      "0x08210F9170F89Ab7658F0b5e3fF39b0E03C594d4", // Circle EURC on Sepolia testnet
  BASE_SEPOLIA: "0x808456652fdb597867f38412077A9182bf77359F", // Circle EURC on Base Sepolia testnet
  LIBERTY:      "0x86f36F210586B3bB4C6570F83C682396141427e4", // Euro Coin on LCX Liberty
};

// LCX — native on Liberty chain, ERC-20 on ETH mainnet
const LCX_CONTRACT: Record<string, string> = {
  ETH: "0x037A54AaB062628C9Bbae1FDB1583c195585fe41",
};

export async function fetchEvmBalance(chain: string, address: string): Promise<ChainBalance | null> {
  const rpcUrl = EVM_RPC[chain];
  if (!rpcUrl) return null;
  try {
    const r = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "eth_getBalance",
        params: [address, "latest"],
        id: 1,
      }),
    });
    const j = await r.json();
    if (!j?.result) return null;
    const wei = BigInt(j.result);
    const eth = Number(wei) / 1e18;
    const symbol = chain === "POLYGON" ? "MATIC"
      : chain === "BSC" ? "BNB"
      : chain === "AVAX" ? "AVAX"
      : "ETH";
    return { native: eth.toFixed(6), symbol, raw: String(wei) };
  } catch {
    return null;
  }
}

// ERC-20 balanceOf via eth_call
async function fetchErc20Balance(
  chain: string,
  tokenAddress: string,
  walletAddress: string,
  decimals: number,
  symbol: string,
): Promise<ChainBalance | null> {
  const rpcUrl = EVM_RPC[chain];
  if (!rpcUrl) return null;
  try {
    // balanceOf(address) = 0x70a08231 + padded address
    const data = "0x70a08231" + walletAddress.replace("0x", "").toLowerCase().padStart(64, "0");
    const r = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "eth_call",
        params: [{ to: tokenAddress, data }, "latest"],
        id: 1,
      }),
    });
    const j = await r.json();
    if (!j?.result || j.result === "0x") return null;
    const raw = BigInt(j.result);
    const amount = Number(raw) / Math.pow(10, decimals);
    return { native: amount.toFixed(decimals === 6 ? 4 : 6), symbol, raw: String(raw) };
  } catch {
    return null;
  }
}

export async function fetchUsdcBalance(chain: string, address: string): Promise<ChainBalance | null> {
  const contract = USDC_CONTRACT[chain];
  if (!contract) return null;
  return fetchErc20Balance(chain, contract, address, 6, "USDC");
}

export async function fetchEurcBalance(chain: string, address: string): Promise<ChainBalance | null> {
  const contract = EURC_CONTRACT[chain];
  if (!contract) return null;
  return fetchErc20Balance(chain, contract, address, 6, "EURC");
}

export async function fetchLcxBalance(chain: string, address: string): Promise<ChainBalance | null> {
  // On Liberty chain, LCX is the native currency (like ETH on Ethereum)
  if (chain === "LIBERTY") return fetchEvmBalance("LIBERTY", address);
  const contract = LCX_CONTRACT[chain];
  if (!contract) return null;
  return fetchErc20Balance(chain, contract, address, 18, "LCX");
}

// Fetch all relevant balances for a given EVM address across all DEX chains
// Returns map: chain+token → ChainBalance
export async function fetchAllEvmBalances(address: string): Promise<Record<string, ChainBalance | null>> {
  const [
    ethSep, usdcSep, eurcSep,
    lcxLib, usdcLib, eurcLib,
    ethBase, usdcBase, eurcBase,
  ] = await Promise.allSettled([
    fetchEvmBalance("SEPOLIA", address),
    fetchUsdcBalance("SEPOLIA", address),
    fetchEurcBalance("SEPOLIA", address),
    fetchLcxBalance("LIBERTY", address),
    fetchUsdcBalance("LIBERTY", address),
    fetchEurcBalance("LIBERTY", address),
    fetchEvmBalance("BASE_SEPOLIA", address),
    fetchUsdcBalance("BASE_SEPOLIA", address),
    fetchEurcBalance("BASE_SEPOLIA", address),
  ]);
  const get = (r: PromiseSettledResult<ChainBalance | null>) =>
    r.status === "fulfilled" ? r.value : null;
  return {
    ETH_SEP:   get(ethSep),
    USDC_SEP:  get(usdcSep),
    EURC_SEP:  get(eurcSep),
    LCX_LIB:   get(lcxLib),
    USDC_LIB:  get(usdcLib),
    EURC_LIB:  get(eurcLib),
    ETH_BASE:  get(ethBase),
    USDC_BASE: get(usdcBase),
    EURC_BASE: get(eurcBase),
  };
}

// ── Solana ───────────────────────────────────────────────────────────────────

// Circle USDC on Solana (SPL token mint address)
const USDC_SOL_MINT: Record<string, string> = {
  devnet:  "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU", // Circle USDC devnet
  mainnet: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", // Circle USDC mainnet
};

export async function fetchSolanaBalance(address: string, cluster: "devnet" | "mainnet" = "devnet"): Promise<ChainBalance | null> {
  const rpc = cluster === "devnet" ? "https://api.devnet.solana.com" : "https://api.mainnet-beta.solana.com";
  try {
    const r = await fetch(rpc, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "getBalance",
        params: [address],
        id: 1,
      }),
    });
    const j = await r.json();
    const lamports: number = j?.result?.value ?? 0;
    const sol = lamports / 1e9;
    return { native: sol.toFixed(6), symbol: "SOL", raw: String(lamports) };
  } catch {
    return null;
  }
}

/** Fetch USDC SPL token balance on Solana devnet/mainnet. */
export async function fetchSolanaUsdcBalance(address: string, cluster: "devnet" | "mainnet" = "devnet"): Promise<ChainBalance | null> {
  const rpcUrl = cluster === "devnet" ? "https://api.devnet.solana.com" : "https://api.mainnet-beta.solana.com";
  const mint = USDC_SOL_MINT[cluster];
  try {
    const r = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "getTokenAccountsByOwner",
        params: [address, { mint }, { encoding: "jsonParsed" }],
        id: 1,
      }),
    });
    const j = await r.json();
    const accounts: any[] = j?.result?.value ?? [];
    if (!accounts.length) return null;
    const uiAmount: number = accounts[0]?.account?.data?.parsed?.info?.tokenAmount?.uiAmount ?? 0;
    const rawAmount: string = accounts[0]?.account?.data?.parsed?.info?.tokenAmount?.amount ?? "0";
    return { native: uiAmount.toFixed(6), symbol: "USDC", raw: rawAmount };
  } catch {
    return null;
  }
}

// ── XRP ──────────────────────────────────────────────────────────────────────

export async function fetchXrpBalance(address: string, network: "testnet" | "mainnet" = "testnet"): Promise<ChainBalance | null> {
  const rpcUrl = network === "testnet"
    ? "https://omnibusblockchain.cc:8443/xrp-testnet/"
    : "https://xrplcluster.com";
  try {
    const r = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        method: "account_info",
        params: [{ account: address, ledger_index: "current" }],
      }),
    });
    const j = await r.json();
    const drops: string = j?.result?.account_data?.Balance ?? "0";
    const xrp = Number(drops) / 1_000_000;
    return { native: xrp.toFixed(6), symbol: "XRP", raw: drops };
  } catch {
    return null;
  }
}

// ── TRON ─────────────────────────────────────────────────────────────────────

async function fetchTronBalance(address: string): Promise<ChainBalance | null> {
  try {
    const r = await fetch(`https://apilist.tronscanapi.com/api/account?address=${address}`);
    if (!r.ok) return null;
    const j = await r.json();
    const sun: number = j?.balance ?? 0;
    const trx = sun / 1e6;
    return { native: trx.toFixed(6), symbol: "TRX", raw: String(sun) };
  } catch {
    return null;
  }
}

// ── Dispatcher — pick fetcher per chain key ──────────────────────────────────

export async function fetchChainBalance(chain: string, address: string): Promise<ChainBalance | null> {
  // Map UI chain key → fetcher
  switch (chain.toUpperCase()) {
    // BTC family
    case "BTC_NATIVE":
    case "BTC_LEGACY":
    case "BTC_SEGWIT":
    case "BTC":
      return fetchBlockchairBalance("bitcoin", address);
    case "LTC":
    case "LTC_NATIVE":
    case "LTC_LEGACY":
      return fetchBlockchairBalance("litecoin", address);
    case "DOGE":
    case "DOGE_LEGACY":
      return fetchBlockchairBalance("dogecoin", address);
    case "BCH":
      return fetchBlockchairBalance("bitcoin-cash", address);

    // EVM family
    case "ETH":
      return fetchEvmBalance("ETH", address);
    case "ARBITRUM":
      return fetchEvmBalance("ARBITRUM", address);
    case "OPTIMISM":
      return fetchEvmBalance("OPTIMISM", address);
    case "POLYGON":
      return fetchEvmBalance("POLYGON", address);
    case "BASE":
      return fetchEvmBalance("BASE", address);
    case "BSC":
      return fetchEvmBalance("BSC", address);
    case "AVAX":
    case "AVALANCHE":
      return fetchEvmBalance("AVAX", address);
    case "SEPOLIA":
      return fetchEvmBalance("SEPOLIA", address);
    case "BASE_SEPOLIA":
      return fetchEvmBalance("BASE_SEPOLIA", address);

    // Other
    case "SOL":
    case "SOLANA":
      return fetchSolanaBalance(address);
    case "TRX":
    case "TRON":
      return fetchTronBalance(address);

    default:
      return null;
  }
}

// ── Send link generator ──────────────────────────────────────────────────────
// Returns a deep-link URL that opens the user's preferred wallet/explorer
// preset to send from the given address. We can't sign cross-chain TXs in
// this React app yet — that's a future session — but we can deep-link.

export function getSendDeepLink(chain: string, fromAddress: string): string {
  const c = chain.toUpperCase();
  // BTC family — open blockchain.com explorer; user copies address into their wallet.
  if (["BTC_NATIVE","BTC_LEGACY","BTC_SEGWIT","BTC"].includes(c)) {
    return `https://www.blockchain.com/explorer/addresses/btc/${fromAddress}`;
  }
  if (c === "LTC" || c === "LTC_NATIVE" || c === "LTC_LEGACY") {
    return `https://blockchair.com/litecoin/address/${fromAddress}`;
  }
  if (c === "DOGE" || c === "DOGE_LEGACY") {
    return `https://dogechain.info/address/${fromAddress}`;
  }
  if (c === "BCH") {
    return `https://blockchair.com/bitcoin-cash/address/${fromAddress}`;
  }
  // EVM — etherscan family
  if (c === "ETH")        return `https://etherscan.io/address/${fromAddress}`;
  if (c === "ARBITRUM")   return `https://arbiscan.io/address/${fromAddress}`;
  if (c === "OPTIMISM")   return `https://optimistic.etherscan.io/address/${fromAddress}`;
  if (c === "POLYGON")    return `https://polygonscan.com/address/${fromAddress}`;
  if (c === "BASE")       return `https://basescan.org/address/${fromAddress}`;
  if (c === "BSC")        return `https://bscscan.com/address/${fromAddress}`;
  if (c === "AVAX" || c === "AVALANCHE") return `https://snowtrace.io/address/${fromAddress}`;
  // Other
  if (c === "SOL" || c === "SOLANA") return `https://solscan.io/account/${fromAddress}`;
  if (c === "TRX" || c === "TRON")   return `https://tronscan.org/#/address/${fromAddress}`;
  return `https://www.google.com/search?q=${chain}+block+explorer+${fromAddress}`;
}
