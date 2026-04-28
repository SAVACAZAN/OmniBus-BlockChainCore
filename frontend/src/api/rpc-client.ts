/**
 * OmniBus RPC Client - TypeScript
 * JSON-RPC 2.0 wrapper for blockchain node
 *
 * Multi-chain: client picks proxy path based on selected chain
 * (persisted in localStorage["omnibus.chain"]). Vite forwards each path
 * to the correct backend RPC port (8332/18332/28332).
 */

export type ChainName = "mainnet" | "testnet" | "regtest";

const CHAIN_KEY = "omnibus.chain";
const VALID_CHAINS: ChainName[] = ["mainnet", "testnet", "regtest"];

// RPC port per chain (matches chain_config.zig). Used to build absolute
// URLs from the browser's window.location.host — bypasses Vite proxy
// (which has been unreliable for prefix routing).
const CHAIN_RPC_PORT: Record<ChainName, number> = {
  mainnet: 8332,
  testnet: 18332,
  regtest: 28332,
};
const CHAIN_WS_PORT: Record<ChainName, number> = {
  mainnet: 8334,
  testnet: 18334,
  regtest: 28334,
};

export function getActiveChain(): ChainName {
  if (typeof localStorage === "undefined") return "mainnet";
  const v = localStorage.getItem(CHAIN_KEY);
  return (VALID_CHAINS.includes(v as ChainName) ? v : "mainnet") as ChainName;
}

export function setActiveChain(c: ChainName) {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(CHAIN_KEY, c);
  // Trigger reload so all stores re-fetch from the new RPC backend.
  window.location.reload();
}

// Build an absolute RPC URL using the current page hostname. This avoids
// Vite's flaky prefix proxy and works whether the page is served from
// localhost, raw IP, or a domain (and whether it's HTTP or HTTPS).
//
// On HTTPS (e.g. https://omnibusblockchain.cc) the browser blocks plain-HTTP
// requests as mixed content. In that case we fall back to a same-origin
// proxy path /api-{chain} (must be served by Caddy/Nginx upstream).
export function rpcUrlFor(chain: ChainName): string {
  if (typeof window === "undefined") return `/api-${chain}`;
  if (window.location.protocol === "https:") {
    return `/api-${chain}`;
  }
  return `${window.location.protocol}//${window.location.hostname}:${CHAIN_RPC_PORT[chain]}`;
}

export function wsUrlFor(chain: ChainName): string {
  if (typeof window === "undefined") return `/ws-${chain}`;
  if (window.location.protocol === "https:") {
    return `wss://${window.location.host}/ws-${chain}`;
  }
  return `ws://${window.location.hostname}:${CHAIN_WS_PORT[chain]}`;
}

interface JsonRpcRequest {
  jsonrpc: string;
  method: string;
  params: any[];
  id: number;
}

interface JsonRpcResponse {
  jsonrpc: string;
  result?: any;
  error?: { code: number; message: string };
  id: number;
}

export class OmniBusRpcClient {
  private baseUrl: string;
  private requestId: number = 1;

  constructor(baseUrl?: string) {
    if (baseUrl) {
      this.baseUrl = baseUrl;
    } else {
      // Auto-pick URL based on chain + page protocol (HTTPS vs HTTP).
      this.baseUrl = rpcUrlFor(getActiveChain());
    }
  }

  private async request(method: string, params: any[] = []): Promise<any> {
    const request: JsonRpcRequest = {
      jsonrpc: "2.0",
      method,
      params,
      id: this.requestId++,
    };

    try {
      const response = await fetch(this.baseUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(request),
      });

      // Some RPC handlers return empty body on unsupported methods.
      // Fall through to a soft-null result instead of throwing a parse error.
      const text = await response.text();
      if (!text) return null;

      let data: JsonRpcResponse;
      try {
        data = JSON.parse(text);
      } catch {
        // Non-JSON response (HTML 500, etc.) — treat as soft fail
        return null;
      }

      if (data.error) {
        throw new Error(`RPC Error: ${data.error.message}`);
      }

      return data.result;
    } catch (error) {
      // "Block not found" is expected during race conditions when UI requests
      // a block at the chain tip that has just been mined but not yet served
      // (or vice-versa). Don't spam console — caller's `.catch(() => null)`
      // handles it. Only log unexpected errors.
      const msg = error instanceof Error ? error.message : String(error);
      if (!msg.includes("Block not found")) {
        console.error(`RPC request failed (${method}):`, error);
      }
      throw error;
    }
  }

  // Raw request (for custom methods)
  async request_raw(method: string, params: any[] = []): Promise<any> {
    return this.request(method, params);
  }

  // Blockchain methods
  async getBlockCount(): Promise<number> {
    return this.request("getblockcount");
  }

  async getBlock(index: number): Promise<any> {
    return this.request("getblock", [index]);
  }

  async getLatestBlock(): Promise<any> {
    return this.request("getlatestblock");
  }

  async getBalance(): Promise<number> {
    return this.request("getbalance");
  }

  async sendTransaction(to: string, amount: number): Promise<string> {
    return this.request("sendtransaction", [to, amount]);
  }

  async getTransaction(txId: string): Promise<any> {
    return this.request("gettransaction", [txId]);
  }

  async getMempoolSize(): Promise<number> {
    return this.request("getmempoolsize");
  }

  async getMempoolTransactions(): Promise<any[]> {
    return this.request("getmempool");
  }

  async getTransactionCount(): Promise<number> {
    try {
      const result = await this.request("gettransactions");
      return result?.count || 0;
    } catch { return 0; }
  }

  async getBlockchainStatsExtended(): Promise<{
    blockCount: number;
    mempoolSize: number;
    balance: number;
    transactionCount: number;
    activeMinerCount: number;
  }> {
    try {
      const [blockCount, mempoolSize, balance, transactionCount, miners] = await Promise.all([
        this.getBlockCount(),
        this.getMempoolSize(),
        this.getBalance(),
        this.getTransactionCount(),
        this.getMinerBalances(),
      ]);

      return {
        blockCount,
        mempoolSize,
        balance,
        transactionCount,
        activeMinerCount: miners.length,
      };
    } catch (error) {
      console.error("Failed to fetch extended stats:", error);
      throw error;
    }
  }

  async getTransactionHistory(limit: number = 20): Promise<any[]> {
    try {
      const result = await this.request("gettransactions");
      return result?.transactions || [];
    } catch { return []; }
  }

  async getMinerBalances(): Promise<any[]> {
    try {
      const result = await this.request("getminerstats");
      if (!result?.miners) return [];
      return result.miners.map((m: any) => ({
        minerName: (m.miner || "").substring(0, 20),
        minerID: (m.miner || "").substring(0, 12),
        address: m.miner || "",
        balanceOmni: (m.currentBalanceSAT || 0) / 1e9,
        blocksMined: m.blocksMined || 0,
      }));
    } catch { return []; }
  }

  async getMiners(): Promise<any[]> {
    return this.getMinerBalances();
  }

  async getPoolStats(): Promise<any> {
    return this.request("getpoolstats");
  }

  /**
   * Faucet status. Returns {enabled, address, balance, grantPerClaim, claimsServed}.
   * `enabled=false` means the node was started without --faucet-mode or
   * without OMNIBUS_FAUCET_PRIVKEY — UI should disable the claim button.
   */
  async getFaucetStatus(): Promise<{
    enabled: boolean;
    address: string;
    balance: number;
    grantPerClaim: number;
    claimsServed: number;
  } | null> {
    try {
      return await this.request("getfaucetstatus");
    } catch {
      return null;
    }
  }

  /**
   * Request 0.1 OMNI from the testnet faucet. Server enforces:
   *   - 1 grant per address ever
   *   - faucet must have ≥ grantPerClaim + fee balance
   * Returns the txid on success; throws Error with the RPC message otherwise.
   */
  async claimFaucet(address: string): Promise<{
    txid: string;
    recipient: string;
    amount: number;
    fee: number;
    status: string;
  }> {
    return this.request("claimfaucet", [address]);
  }

  async getMempoolStats(): Promise<any> {
    return this.request("getmempoolstats");
  }

  async getPeers(): Promise<any> {
    return this.request("getpeers");
  }

  async getSyncStatus(): Promise<any> {
    return this.request("getsyncstatus");
  }

  async getNetworkInfo(): Promise<any> {
    return this.request("getnetworkinfo");
  }

  async getNodeList(): Promise<any> {
    return this.request("getnodelist");
  }

  async getBlocks(from: number, count: number = 10): Promise<any> {
    return this.request("getblocks", [from, count]);
  }

  async getMinerInfo(): Promise<any> {
    return this.request("getminerinfo");
  }

  async getMinerStatus(): Promise<any> {
    return this.request("getminerstatus");
  }

  async registerMiner(minerData: any): Promise<any> {
    return this.request("registerminer", [minerData]);
  }

  async minerKeepalive(address: string): Promise<any> {
    return this.request("minerkeepalive", [address]);
  }

  // ── New RPC endpoints ──────────────────────────────────────────────────

  async getTransactionDetail(txid: string): Promise<any> {
    return this.request("gettransaction", [txid]);
  }

  async getAddressHistory(address: string): Promise<any> {
    return this.request("getaddresshistory", [address]);
  }

  async listTransactions(count: number = 20): Promise<any> {
    return this.request("listtransactions", [count]);
  }

  async estimateFee(): Promise<any> {
    return this.request("estimatefee");
  }

  async getNonce(address: string): Promise<any> {
    return this.request("getnonce", [address]);
  }

  async getHeaders(fromHeight: number, count: number = 10): Promise<any> {
    return this.request("getheaders", [fromHeight, count]);
  }

  async getMerkleProof(txid: string): Promise<any> {
    return this.request("getmerkleproof", [txid]);
  }

  // Custom methods for UI
  async getBlockchainStats(): Promise<{
    blockCount: number;
    mempoolSize: number;
    balance: number;
  }> {
    try {
      const [blockCount, mempoolSize, balance] = await Promise.all([
        this.getBlockCount(),
        this.getMempoolSize(),
        this.getBalance(),
      ]);

      return { blockCount, mempoolSize, balance };
    } catch (error) {
      console.error("Failed to fetch stats:", error);
      throw error;
    }
  }

  async getRecentBlocks(count: number = 10): Promise<any[]> {
    try {
      const totalBlocks = await this.getBlockCount();
      const blocks = [];

      for (
        let i = Math.max(0, totalBlocks - count);
        i < totalBlocks;
        i++
      ) {
        const block = await this.getBlock(i);
        blocks.push(block);
      }

      return blocks.reverse();
    } catch (error) {
      console.error("Failed to fetch recent blocks:", error);
      return [];
    }
  }

  // ── Native DEX (matching engine on-chain) ────────────────────────────
  // Server: rpc_server.zig handlers `exchange_*`. Prices in micro-USD,
  // amounts in SAT. All write methods need a wallet signature; see
  // `signOrderPayload` and `signCancelPayload` in api/exchange-sign.ts.

  async exchangeListPairs(): Promise<Array<{
    id: number;
    base: string;
    quote: string;
    label: string;
  }>> {
    try {
      return (await this.request("exchange_listPairs")) || [];
    } catch {
      return [];
    }
  }

  async exchangeGetOrderbook(params: {
    pair?: string;
    pairId?: number;
    depth?: number;
  }): Promise<{
    pairId: number;
    bids: Array<OrderbookLevel>;
    asks: Array<OrderbookLevel>;
    bestBid: number;
    bestAsk: number;
    spread: number;
    orderCount: number;
  } | null> {
    try {
      return await this.request("exchange_getOrderbook", [params]);
    } catch {
      return null;
    }
  }

  async exchangeGetUserOrders(params: {
    trader: string;
    pair?: string;
    pairId?: number;
  }): Promise<UserOrder[]> {
    try {
      return (await this.request("exchange_getUserOrders", [params])) || [];
    } catch {
      return [];
    }
  }

  async exchangeGetTrades(params: {
    pair?: string;
    pairId?: number;
    address?: string;
    limit?: number;
  } = {}): Promise<TradeFill[]> {
    try {
      return (await this.request("exchange_getTrades", [params])) || [];
    } catch {
      return [];
    }
  }

  async exchangeGetStats(): Promise<{
    totalOrders: number;
    bidCount: number;
    askCount: number;
    trades: number;
    pairs: Array<{
      id: number;
      label: string;
      bestBid: number;
      bestAsk: number;
      spread: number;
      orderCount: number;
    }>;
  } | null> {
    try {
      return await this.request("exchange_getStats");
    } catch {
      return null;
    }
  }

  async exchangePlaceOrder(payload: {
    trader: string;
    side: "buy" | "sell";
    pair?: string;
    pairId?: number;
    price: number;
    amount: number;
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<{
    orderId: number;
    side: string;
    pairId: number;
    price: number;
    amount: number;
    filled: number;
    remaining: number;
    status: string;
  }> {
    return this.request("exchange_placeOrder", [payload]);
  }

  async exchangeCancelOrder(payload: {
    orderId: number;
    trader: string;
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<{ orderId: number; cancelled: boolean }> {
    return this.request("exchange_cancelOrder", [payload]);
  }

  // ── Login flow (signed nonce) ─────────────────────────────────────
  async exchangeGetAuthNonce(address: string): Promise<{
    nonce: string;
    message: string;
    ttlMs: number;
  }> {
    return this.request("exchange_getAuthNonce", [{ address }]);
  }

  async exchangeLogin(payload: {
    address: string;
    nonce: string;
    signature: string;
    publicKey: string;
  }): Promise<{ address: string; loggedIn: boolean; sessionTtlMs: number }> {
    return this.request("exchange_login", [payload]);
  }

  // ── API keys ──────────────────────────────────────────────────────
  async exchangeCreateApiKey(payload: {
    owner: string;
    name: string;
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<{
    keyId: string;
    secret: string;
    name: string;
    warning: string;
    createdMs: number;
  }> {
    return this.request("exchange_createApiKey", [payload]);
  }

  async exchangeListApiKeys(owner: string): Promise<ApiKeyInfo[]> {
    try {
      return (await this.request("exchange_listApiKeys", [{ owner }])) || [];
    } catch {
      return [];
    }
  }

  async exchangeRevokeApiKey(payload: {
    owner: string;
    keyId: string;
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<{ keyId: string; revoked: boolean }> {
    return this.request("exchange_revokeApiKey", [payload]);
  }

  // ── Deposit / Withdraw / Balances ─────────────────────────────────
  async exchangeDeposit(payload: {
    owner: string;
    token: string;
    amount: number;
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<ExchangeBalance> {
    return this.request("exchange_deposit", [payload]);
  }

  async exchangeWithdraw(payload: {
    owner: string;
    token: string;
    amount: number;
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<ExchangeBalance> {
    return this.request("exchange_withdraw", [payload]);
  }

  async exchangeGetBalances(owner: string): Promise<ExchangeBalance[]> {
    try {
      return (await this.request("exchange_getBalances", [{ owner }])) || [];
    } catch {
      return [];
    }
  }

  // ── Identity (public nickname / ENS pref / visibility) ──────────────
  async identitySet(payload: {
    address: string;
    nickname: string;
    ens: string;
    visibility: "public" | "private" | "ens_only";
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<{ address: string; nickname: string; ens: string; visibility: string; updated: boolean }> {
    return this.request("identity_set", [payload]);
  }

  async identityGet(address: string): Promise<{
    address: string;
    nickname: string;
    ens: string;
    visibility: "public" | "private" | "ens_only";
    updated: number;
  } | null> {
    try {
      return await this.request("identity_get", [{ address }]);
    } catch {
      return null;
    }
  }

  async identitySearch(prefix: string, limit = 25): Promise<Array<{
    address: string;
    nickname: string;
    ens: string;
    visibility: string;
  }>> {
    try {
      return (await this.request("identity_search", [{ prefix, limit }])) || [];
    } catch {
      return [];
    }
  }

  // ── KYC (signed attestations, no PII on chain) ─────────────────────
  async kycGetStatus(address: string): Promise<{
    address: string;
    level: 0 | 1 | 2 | 3;
    label: string;
    issuer?: string;
    issued?: number;
    expires?: number;
  }> {
    try {
      return await this.request("kyc_getStatus", [{ address }]);
    } catch {
      return { address, level: 0, label: "none" };
    }
  }

  async kycListIssuers(): Promise<Array<{ address: string; role: string; slot: number }>> {
    try {
      return (await this.request("kyc_listIssuers")) || [];
    } catch {
      return [];
    }
  }

  async kycAttest(payload: {
    address: string;
    level: 1 | 2 | 3;
    issued: number;
    expires: number;
    signature: string;
    publicKey: string;
  }): Promise<{ address: string; level: number; label: string; issuer: string; issued: number; expires: number }> {
    return this.request("kyc_attest", [payload]);
  }
}

export interface ApiKeyInfo {
  keyId: string;
  name: string;
  createdMs: number;
  lastUsedMs: number;
  revoked: boolean;
}

export interface ExchangeBalance {
  token: string;
  available: number;
  locked: number;
  owner?: string;
}

export interface OrderbookLevel {
  orderId: number;
  price: number;
  amount: number;
  remaining: number;
  trader: string;
  ts: number;
}

export interface UserOrder {
  orderId: number;
  side: string;
  pairId: number;
  price: number;
  amount: number;
  filled: number;
  remaining: number;
  status: string;
  ts: number;
}

export interface TradeFill {
  fillId: number;
  pairId: number;
  price: number;
  amount: number;
  buyer: string;
  seller: string;
  buyOrderId: number;
  sellOrderId: number;
  ts: number;
}

export default OmniBusRpcClient;
