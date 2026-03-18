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

  constructor(baseUrl: string = "http://localhost:8332") {
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
