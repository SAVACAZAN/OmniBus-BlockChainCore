/**
 * OmniBus RPC Client - TypeScript
 * JSON-RPC 2.0 wrapper for blockchain node
 */

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

  constructor(baseUrl: string = "/api") {
    this.baseUrl = baseUrl;
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

      const data: JsonRpcResponse = await response.json();

      if (data.error) {
        throw new Error(`RPC Error: ${data.error.message}`);
      }

      return data.result;
    } catch (error) {
      console.error(`RPC request failed (${method}):`, error);
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
}

export default OmniBusRpcClient;
