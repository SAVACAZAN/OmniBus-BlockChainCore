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

// ── EVM (ETH + L2s) ──────────────────────────────────────────────────────────
// Uses public RPC endpoints. eth_getBalance returns wei.

const EVM_RPC: Record<string, string> = {
  ETH:       "https://eth.llamarpc.com",
  ARBITRUM:  "https://arb1.arbitrum.io/rpc",
  OPTIMISM:  "https://mainnet.optimism.io",
  POLYGON:   "https://polygon-rpc.com",
  BASE:      "https://mainnet.base.org",
  BSC:       "https://bsc-dataseed.binance.org",
  AVAX:      "https://api.avax.network/ext/bc/C/rpc",
};

async function fetchEvmBalance(chain: string, address: string): Promise<ChainBalance | null> {
  const rpc = EVM_RPC[chain];
  if (!rpc) return null;
  try {
    const r = await fetch(rpc, {
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
    // ETH has 18 decimals — show 6 fractional digits
    const eth = Number(wei) / 1e18;
    const symbol = chain === "ETH" ? "ETH"
      : chain === "POLYGON" ? "MATIC"
      : chain === "BSC" ? "BNB"
      : chain === "AVAX" ? "AVAX"
      : "ETH";
    return { native: eth.toFixed(6), symbol, raw: String(wei) };
  } catch {
    return null;
  }
}

// ── Solana ───────────────────────────────────────────────────────────────────

async function fetchSolanaBalance(address: string): Promise<ChainBalance | null> {
  try {
    const r = await fetch("https://api.mainnet-beta.solana.com", {
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
