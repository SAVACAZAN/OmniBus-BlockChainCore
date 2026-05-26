/**
 * OmniBus RPC Client - TypeScript
 * JSON-RPC 2.0 wrapper for blockchain node
 *
 * Multi-chain: client picks proxy path based on selected chain
 * (persisted in localStorage["omnibus.chain"]). Vite forwards each path
 * to the correct backend RPC port (8332/18332/28332).
 */

import { SAT_PER_OMNI } from "../utils/fmt";

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
  private fixedUrl: string | null;
  private requestId: number = 1;

  constructor(baseUrl?: string) {
    // If explicit URL given, pin it. Otherwise read chain from localStorage
    // at every request so a chain-switch (setActiveChain) is picked up
    // without needing to recreate the client.
    this.fixedUrl = baseUrl ?? null;
  }

  private get baseUrl(): string {
    return this.fixedUrl ?? rpcUrlFor(getActiveChain());
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
      // (or vice-versa). "Method not found" is expected when the UI is newer
      // than the node (e.g. treasury_* RPCs landed in a later chain build —
      // the older deployed node legitimately doesn't expose them yet, the
      // caller already gates the panel on this). Don't spam console for these.
      const msg = error instanceof Error ? error.message : String(error);
      const muted = msg.includes("Block not found")
        || msg.includes("Method not found")
        || msg.includes("not enabled");
      if (!muted) {
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

  async pqSend(p: {
    from: string;
    to: string;
    amount: number;
    scheme: string;
    signature: string;
    public_key: string;
    id: number;
    timestamp: number;
    nonce: number;
    fee?: number;
    op_return?: string;
  }): Promise<{ txid?: string; hash?: string; error?: string }> {
    return this.request("pq_send", [p]);
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
        balanceOmni: (m.currentBalanceSAT || 0) / SAT_PER_OMNI,
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
   * Faucet status. Returns protocol faucet info including declaration hash/text.
   * `enabled=false` means balance is depleted — donations welcome at faucet address.
   */
  async getFaucetStatus(): Promise<{
    enabled: boolean;
    address: string;
    balance: number;
    grantPerClaim: number;
    cooldownHours: number;
    declaration_hash: string;
    declaration_text: string;
  } | null> {
    try {
      return await this.request("getfaucetstatus");
    } catch {
      return null;
    }
  }

  /**
   * Claim from the protocol faucet. Requires the declaration_hash from getfaucetstatus.
   * The claimer must provide their wallet signature to prove identity and agreement.
   * One claim per address ever; IP cooldown enforced server-side.
   */
  async claimFaucet(address: string, declarationHash: string): Promise<{
    txid: string;
    recipient: string;
    amount: number;
    declaration: string;
    status: string;
    message: string;
  }> {
    // Note: full signing flow requires wallet private key — for now sends
    // declaration_hash as proof of reading. Full sig enforcement in Phase 2.
    return this.request("claimfaucet", [{
      address,
      declaration_hash: declarationHash,
      signature: "00".repeat(64),   // placeholder — node validates decl_hash only for now
      public_key: "00".repeat(33),
      nonce: 0,
    }]);
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

  async getNonce(address: string): Promise<number> {
    const r = await this.request("getnonce", [address]) as
      { nonce?: number; chainNonce?: number } | number | null;
    return typeof r === "number" ? r : (r?.nonce ?? 0);
  }

  async getAddressBalance(address: string): Promise<{ address: string; balance: number; balanceOMNI: number } | null> {
    try {
      return await this.request("getaddressbalance", [address]);
    } catch {
      return null;
    }
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
    mode?: "real" | "paper";
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
    mode?: "real" | "paper";
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
    mode?: "real" | "paper";
  } = {}): Promise<TradeFill[]> {
    try {
      return (await this.request("exchange_getTrades", [params])) || [];
    } catch {
      return [];
    }
  }

  async exchangeGetStats(mode?: "real" | "paper"): Promise<{
    mode?: string;
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
      return await this.request("exchange_getStats", [{ mode }]);
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
    mode?: "real" | "paper";
    taker_chain?: string;
    sellerEvm?: string;
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
    mode?: "real" | "paper";
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
    // Read BOTH the legacy kyc_getStatus (issuer-signed levels 0-3) and
    // the newer mica_disclose (MiCA-style kind tags). The chain has two
    // parallel attestation paths and any single one being set should
    // unlock the UI — otherwise users who self-attested via mica_attest
    // see "level 0" even though their attestation is on-chain.
    let legacy = { address, level: 0 as 0 | 1 | 2 | 3, label: "none" };
    try {
      legacy = await this.request("kyc_getStatus", [{ address }]);
    } catch { /* fall back to mica below */ }
    if (legacy.level > 0) return legacy;

    // Map MiCA kinds → tier: kyc → 1, aml → 2, sanctions → 3.
    try {
      const m = await this.request("mica_disclose", [{ address }]);
      const kinds = new Set<string>(
        (m?.attestations ?? []).map((a: { kind: string }) => a.kind),
      );
      let level: 0 | 1 | 2 | 3 = 0;
      if (kinds.has("kyc")) level = 1;
      if (kinds.has("aml")) level = 2;
      if (kinds.has("sanctions")) level = 3;
      if (level > 0) {
        return {
          address,
          level,
          label: level === 1 ? "tier-1" : level === 2 ? "tier-2" : "tier-3",
          issuer: m?.attestations?.[0]?.issuer_did,
          issued: m?.attestations?.[0]?.timestamp,
        };
      }
    } catch { /* both paths empty → level 0 */ }

    return legacy;
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

  // ── Grid trading engine ────────────────────────────────────────────
  async gridCreate(params: {
    pair_id: number;
    price_low: number;
    price_high: number;
    levels: number;
    total_base: number;
    total_quote: number;
    owner: string;
  }): Promise<{ grid_id: number; levels_generated: number; buy_orders: number; sell_orders: number; price_step: number }> {
    return this.request("grid_create", [params]);
  }

  async gridList(owner?: string): Promise<GridConfig[]> {
    try {
      return (await this.request("grid_list", [owner ? { owner } : {}])) || [];
    } catch {
      return [];
    }
  }

  async gridStatus(grid_id: number): Promise<GridStatus | null> {
    try {
      return await this.request("grid_status", [{ grid_id }]);
    } catch {
      return null;
    }
  }

  async gridCancel(grid_id: number, owner: string): Promise<{ grid_id: number; cancelled: boolean }> {
    return this.request("grid_cancel", [{ grid_id, owner }]);
  }

  async exchangePairInfo(pair_id: number): Promise<PairInfo | null> {
    try {
      return await this.request("exchange_pairInfo", [{ pair_id }]);
    } catch {
      return null;
    }
  }

  // ── Identity profiles (4-facet, MiCA-compliant) ───────────────────────
  // `profile_init` is fire-and-forget right after mnemonic confirm. Returns
  // a server-allocated salt for selective disclosure. Idempotent: calling
  // again on an address that already has a profile returns the existing salt
  // (chain enforces "first init wins").
  async profileInit(address: string): Promise<ProfileInitResult | null> {
    try {
      return await this.request("profile_init", [{ address }]);
    } catch {
      return null;
    }
  }

  async profileGet(address: string): Promise<ProfileFull | null> {
    try {
      return await this.request("profile_get", [{ address }]);
    } catch {
      return null;
    }
  }

  async profileUpdate(payload: {
    address: string;
    facet: ProfileFacet;
    fields: Record<string, unknown>;
    visibility_mask: Record<string, "public" | "private">;
    nonce: number;
    signature: string;
    publicKey: string;
  }): Promise<{ address: string; facet: string; updated: boolean }> {
    return this.request("profile_update", [payload]);
  }

  async micaAttest(payload: {
    address: string;
    kind: "kyc" | "aml" | "sanctions" | "issuer";
    valid_until?: number;
    white_paper_hash?: string;
    risk_category?: "low" | "medium" | "high";
    /** Optional — only required when the chain enforces issuer signatures.
     *  When `self: true` is set, the chain accepts the call without
     *  a signature (testnet self-attest path). */
    nonce?: number;
    signature?: string;
    publicKey?: string;
    /** Testnet shortcut — when true, the chain records the attestation
     *  without verifying the issuer signature. Used by the KYC UI for
     *  self-attestation when no real issuer service is wired up. */
    self?: boolean;
  }): Promise<MicaAttestation> {
    return this.request("mica_attest", [payload]);
  }

  async micaDisclose(address: string): Promise<MicaDisclosure | null> {
    try {
      return await this.request("mica_disclose", [{ address }]);
    } catch {
      return null;
    }
  }

  // ── Cold Wallet (watch-only) ──────────────────────────────────────────────

  async coldwalletAdd(address: string, label: string): Promise<{ added: boolean }> {
    return this.request("coldwallet_add", [{ address, label }]);
  }

  async coldwalletList(): Promise<ColdWalletListResult> {
    try {
      return (await this.request("coldwallet_list", [{}])) ?? { addresses: [] };
    } catch {
      return { addresses: [] };
    }
  }

  async coldwalletRemove(address: string): Promise<{ removed: boolean }> {
    return this.request("coldwallet_remove", [{ address }]);
  }

  async coldwalletHistory(address: string, limit = 50): Promise<ColdWalletHistoryResult> {
    try {
      return (await this.request("coldwallet_history", [{ address, limit }])) ?? { transactions: [] };
    } catch {
      return { transactions: [] };
    }
  }

  // ── Timelock (CLTV) ───────────────────────────────────────────────────────

  async timelockCreate(params: {
    owner: string;
    dest: string;
    amount_sat: number;
    unlock_block: number;
  }): Promise<TimelockCreateResult> {
    return this.request("timelock_create", [params]);
  }

  async timelockList(owner?: string): Promise<TimelockListResult> {
    try {
      return (await this.request("timelock_list", [owner ? { owner } : {}])) ?? { vaults: [] };
    } catch {
      return { vaults: [] };
    }
  }

  async timelockSpend(vault_id: string): Promise<{ vault_id: string; txid: string; spent: boolean }> {
    return this.request("timelock_spend", [{ vault_id }]);
  }

  async timelockStatus(vault_id: string): Promise<TimelockVault | null> {
    try {
      return await this.request("timelock_status", [{ vault_id }]);
    } catch {
      return null;
    }
  }

  // ── Covenant ──────────────────────────────────────────────────────────────

  async covenantCreate(params: {
    address: string;
    whitelist: string[];
    max_per_tx_sat?: number;
    expires_block?: number;
    label: string;
  }): Promise<{ address: string; created: boolean }> {
    return this.request("covenant_create", [params]);
  }

  async covenantList(): Promise<CovenantListResult> {
    try {
      return (await this.request("covenant_list", [{}])) ?? { covenants: [] };
    } catch {
      return { covenants: [] };
    }
  }

  async covenantGet(address: string): Promise<CovenantEntry | null> {
    try {
      return await this.request("covenant_get", [{ address }]);
    } catch {
      return null;
    }
  }

  async covenantRemove(address: string): Promise<{ address: string; removed: boolean }> {
    return this.request("covenant_remove", [{ address }]);
  }

  // ── Treasury ──────────────────────────────────────────────────────────────

  async treasuryCreate(params: {
    address: string;
    destinations: TreasuryDest[];
    trigger_sat: number;
    label: string;
  }): Promise<{ treasury_id: string; created: boolean }> {
    return this.request("treasury_create", [params]);
  }

  async treasuryList(): Promise<TreasuryListResult> {
    try {
      return (await this.request("treasury_list", [{}])) ?? { treasuries: [] };
    } catch {
      return { treasuries: [] };
    }
  }

  async treasuryDistribute(treasury_id: string): Promise<TreasuryDistributeResult> {
    return this.request("treasury_distribute", [{ treasury_id }]);
  }

  async treasuryStatus(treasury_id: string): Promise<TreasuryEntry | null> {
    try {
      return await this.request("treasury_status", [{ treasury_id }]);
    } catch {
      return null;
    }
  }

  // ── Multisig ──────────────────────────────────────────────────────────────

  async createMultisig(m: number, pubkeys: string[]): Promise<MultisigCreateResult> {
    return this.request("createmultisig", [{ m, pubkeys }]);
  }

  async sendMultisig(params: {
    from: string;
    to: string;
    amount_sat: number;
    fee_sat: number;
    privkeys: string[];
  }): Promise<{ txid: string; sent: boolean }> {
    return this.request("sendmultisig", [params]);
  }
}

export type ProfileFacet = "social" | "professional" | "cultural" | "economic";

export interface ProfileInitResult {
  address: string;
  did: string;
  salt: string;
  created: number;
}

export interface ProfileSocial {
  handle?: string;
  bio?: string;
  avatar?: string;
  links?: Array<{ label: string; url: string }>;
}

export interface ProfileProfessional {
  certifications?: Array<{ issuer: string; title: string; year?: number }>;
  work_history?: Array<{ org: string; role: string; start?: string; end?: string }>;
  skills?: string[];
}

export interface ProfileCultural {
  poaps?: Array<{ event: string; date?: string; proof?: string }>;
  notarized_works?: Array<{ title: string; hash: string; year?: number }>;
  languages?: string[];
  badges?: string[];
}

export interface ProfileEconomic {
  addresses?: Array<{ chain: string; address: string }>;
  donations?: Array<{ to: string; amount: number; ts?: number }>;
  total_volume?: number;
  mica_issuer?: boolean;
  white_paper_hash?: string;
  risk_category?: "low" | "medium" | "high";
}

export interface ProfileFull {
  address: string;
  did: string;
  created: number;
  updated: number;
  obm?: {
    love: number;
    food: number;
    rent: number;
    vacation: number;
    reputation: number;
  };
  social?: ProfileSocial;
  professional?: ProfileProfessional;
  cultural?: ProfileCultural;
  economic?: ProfileEconomic;
  visibility_mask?: Record<string, "public" | "private">;
}

export interface MicaAttestation {
  address: string;
  kind: string;
  issuer: string;
  issued: number;
  valid_until?: number;
  status: "valid" | "expired" | "revoked";
}

export interface MicaDisclosure {
  address: string;
  kyc?: MicaAttestation;
  aml?: MicaAttestation;
  sanctions?: MicaAttestation;
  issuer?: MicaAttestation & { white_paper_hash?: string; risk_category?: string };
}

export interface GridConfig {
  grid_id: number;
  pair_id: number;
  owner: string;
  price_low: number;
  price_high: number;
  levels: number;
  total_base: number;
  total_quote: number;
  filled_count: number;
  profit_quote: number;
  active: boolean;
  created_block: number;
}

export interface GridStatus extends GridConfig {
  buy_levels: Array<{ level: number; price: number; amount: number }>;
  sell_levels: Array<{ level: number; price: number; amount: number }>;
}

export interface PairChain {
  chain: string;
  chain_id: number;
  contract: string;
}

export interface PairInfo {
  pair_id: number;
  base: string;
  quote: string;
  label: string;
  maker_chains: PairChain[];
  taker_chains: PairChain[];
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

// ── Cold Wallet types ─────────────────────────────────────────────────────

export interface ColdWalletEntry {
  address: string;
  label: string;
  balance_sat: number;
  added_at?: number;
}

export interface ColdWalletTx {
  txid: string;
  amount_sat: number;
  block_height: number | null;
  direction: "received" | "sent";
  ts?: number;
}

export interface ColdWalletListResult {
  addresses: ColdWalletEntry[];
}

export interface ColdWalletHistoryResult {
  transactions: ColdWalletTx[];
}

// ── Timelock types ────────────────────────────────────────────────────────

export type TimelockVaultState = "locked" | "unlocked" | "spent";

export interface TimelockVault {
  vault_id: string;
  owner: string;
  dest: string;
  amount_sat: number;
  unlock_block: number;
  created_block: number;
  state: TimelockVaultState;
}

export interface TimelockCreateResult {
  vault_id: string;
  created: boolean;
}

export interface TimelockListResult {
  vaults: TimelockVault[];
}

// ── Covenant types ────────────────────────────────────────────────────────

export interface CovenantEntry {
  address: string;
  label: string;
  whitelist: string[];
  max_per_tx_sat?: number;
  expires_block?: number;
  created_block?: number;
}

export interface CovenantListResult {
  covenants: CovenantEntry[];
}

// ── Treasury types ────────────────────────────────────────────────────────

export interface TreasuryDest {
  address: string;
  percent: number;
  label: string;
}

export interface TreasuryEntry {
  treasury_id: string;
  address: string;
  label: string;
  balance_sat: number;
  trigger_sat: number;
  destinations: TreasuryDest[];
  last_distribute_block?: number;
  last_distribute_ts?: number;
}

export interface TreasuryListResult {
  treasuries: TreasuryEntry[];
}

export interface TreasuryDistributeResult {
  treasury_id: string;
  distributed: boolean;
  total_sat: number;
  splits: Array<{ address: string; amount_sat: number }>;
}

// ── Multisig types ────────────────────────────────────────────────────────

export interface MultisigCreateResult {
  address: string;
  redeemScript: string;
  m: number;
  n: number;
}

export default OmniBusRpcClient;
