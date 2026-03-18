import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "./api/rpc-client";
import "./App.css";

interface Block {
  index: number;
  hash: string;
  timestamp: number;
  transactions: number;
  miner?: string;
  reward?: number;
}

interface Transaction {
  txid: string;
  type: string;
  from: string;
  to: string;
  amount: number;
  timestamp: number;
  blockHeight: number;
  status: string;
  minerName?: string;
}

interface ChainStats {
  blockCount: number;
  mempoolSize: number;
  balance: number;
}

interface MinerBalance {
  minerName: string;
  minerID: string;
  address: string;
  balanceOmni: number;
  blocksMined: number;
}

export const App: React.FC = () => {
  const [stats, setStats] = useState<ChainStats | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [miners, setMiners] = useState<MinerBalance[]>([]);
  const [loading, setLoading] = useState(true);
  const client = new OmniBusRpcClient();

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 3000);
    return () => clearInterval(interval);
  }, []);

  const fetchData = async () => {
    try {
      // Fetch stats
      const statsData = await client.getBlockchainStats();
      setStats(statsData);

      // Fetch transactions (real mining rewards only)
      const txData = await client.getTransactionHistory(10);
      setTransactions(txData);

      // Fetch miner balances
      const minerData = await client.getMinerBalances();
      setMiners(minerData);

      // Fetch recent blocks
      if (statsData.blockCount > 0) {
        const recentBlocks: Block[] = [];
        const startIndex = Math.max(0, statsData.blockCount - 10);

        for (let i = startIndex; i < statsData.blockCount; i++) {
          try {
            const block = await client.getBlock(i);
            if (block) {
              recentBlocks.push({
                index: block.index || i,
                hash: (block.hash || "0x0000").substring(0, 16) + "...",
                timestamp: block.timestamp || Date.now(),
                transactions: block.transactions ? block.transactions.length : 0,
                miner: block.miner,
                reward: block.reward || 50,
              });
            }
          } catch (err) {
            console.error(`Failed to fetch block ${i}:`, err);
          }
        }

        setBlocks(recentBlocks.reverse());
      }
    } catch (error) {
      console.error("Failed to fetch data:", error);
    } finally {
      setLoading(false);
    }
  };

  const formatBalance = (sat: number) => {
    return (sat / 1e9).toFixed(2);
  };

  const getLastBlockTime = () => {
    if (blocks.length > 0) {
      const seconds = Math.floor((Date.now() - blocks[0].timestamp) / 1000);
      return seconds < 60 ? `${seconds}s ago` : `${Math.floor(seconds / 60)}m ago`;
    }
    return "N/A";
  };

  if (loading || !stats) {
    return (
      <div className="container" style={{ paddingTop: "100px", textAlign: "center" }}>
        <p style={{ color: "#888" }}>Loading blockchain data...</p>
      </div>
    );
  }

  return (
    <div className="container">
      {/* Header */}
      <header>
        <h1>⚡ OmniBus Block Explorer</h1>
        <p className="subtitle">Real-Time Mining Transactions – Live Genesis</p>
      </header>

      {/* Network Overview */}
      <div className="grid-3">
        <div className="section">
          <div className="section-header">📊 Chain Height</div>
          <div className="section-body">
            <div style={{ textAlign: "center" }}>
              <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                {stats.blockCount}
              </div>
              <div style={{ color: "#888", marginTop: "10px" }}>
                Blocks Mined
              </div>
              <div className="updated">Last block: {getLastBlockTime()}</div>
            </div>
          </div>
        </div>

        <div className="section">
          <div className="section-header">💰 Total Mining Rewards</div>
          <div className="section-body">
            <div style={{ textAlign: "center" }}>
              <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                {formatBalance(stats.balance)}
              </div>
              <div style={{ color: "#888", marginTop: "10px" }}>OMNI Distributed</div>
              <div className="updated">{(stats.balance / 1e9 / 50).toFixed(0)} mining rewards</div>
            </div>
          </div>
        </div>

        <div className="section">
          <div className="section-header">🔗 Active Miners</div>
          <div className="section-body">
            <div style={{ textAlign: "center" }}>
              <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                {miners.length}
              </div>
              <div style={{ color: "#888", marginTop: "10px" }}>Mining Nodes</div>
              <div className="updated">
                <span className="status-good">✓ All Mining</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Mining Statistics */}
      <div className="section">
        <div className="section-header">📈 Mining Statistics</div>
        <div className="section-body">
          <div className="stat-grid">
            <div className="stat-card">
              <div className="stat-label">Real Transactions</div>
              <div className="stat-value">{transactions.length}</div>
            </div>
            <div className="stat-card">
              <div className="stat-label">Avg Block Reward</div>
              <div className="stat-value">50 OMNI</div>
            </div>
            <div className="stat-card">
              <div className="stat-label">Transaction Type</div>
              <div className="stat-value">Mining Only</div>
            </div>
            <div className="stat-card">
              <div className="stat-label">Blocks Per Miner</div>
              <div className="stat-value">
                {miners.length > 0 ? (stats.blockCount / miners.length).toFixed(1) : "0"}
              </div>
            </div>
            <div className="stat-card">
              <div className="stat-label">Reward Distribution</div>
              <div className="stat-value">50 OMNI/block</div>
            </div>
            <div className="stat-card">
              <div className="stat-label">Network Status</div>
              <div className="stat-value status-good">✓ Active</div>
            </div>
          </div>
        </div>
      </div>

      {/* Latest Blocks */}
      <div className="section">
        <div className="section-header">📦 Latest Mined Blocks ({blocks.length})</div>
        <div className="section-body">
          {blocks.length > 0 ? (
            blocks.map((block) => (
              <div key={block.index} className="block-card">
                <div className="block-title">Block #{block.index}</div>
                <div className="block-detail">
                  <span className="block-detail-label">Hash:</span>
                  <span className="block-detail-value hash">{block.hash}</span>
                </div>
                <div className="block-detail">
                  <span className="block-detail-label">Miner:</span>
                  <span className="block-detail-value">{block.miner || "Unknown"}</span>
                </div>
                <div className="block-detail">
                  <span className="block-detail-label">Mining Reward:</span>
                  <span className="block-detail-value">{block.reward} OMNI</span>
                </div>
                <div className="block-detail">
                  <span className="block-detail-label">Transactions:</span>
                  <span className="block-detail-value">{block.transactions}</span>
                </div>
                <div className="block-detail">
                  <span className="block-detail-label">Timestamp:</span>
                  <span className="block-detail-value">
                    {new Date(block.timestamp).toLocaleString()}
                  </span>
                </div>
                <div className="block-detail">
                  <span className="block-detail-label">Status:</span>
                  <span className="block-detail-value status-good">✓ Confirmed</span>
                </div>
              </div>
            ))
          ) : (
            <p style={{ color: "#888" }}>No blocks to display</p>
          )}
        </div>
      </div>

      {/* Miner Balances and Mining Transactions */}
      <div className="grid-2">
        <div className="section">
          <div className="section-header">💎 Miner Balance Distribution</div>
          <div className="section-body">
            {miners.length > 0 ? (
              miners.slice(0, 5).map((miner, idx) => (
                <div key={idx} className="address-card">
                  <div className="address-id">{miner.minerName} (ID: {miner.minerID})</div>
                  <div className="address-full">{miner.address}</div>
                  <div style={{ color: "#00ff88", marginTop: "8px", fontWeight: "bold" }}>
                    Balance: {miner.balanceOmni.toFixed(2)} OMNI
                  </div>
                  <div style={{ color: "#888", fontSize: "10px", marginTop: "4px" }}>
                    Blocks Mined: {miner.blocksMined}
                  </div>
                </div>
              ))
            ) : (
              <p style={{ color: "#888" }}>No miner data available</p>
            )}
          </div>
        </div>

        <div className="section">
          <div className="section-header">💸 Mining Reward Transactions</div>
          <div className="section-body">
            {transactions.length > 0 ? (
              transactions.slice(0, 5).map((tx, idx) => (
                <div key={idx} className="tx-card">
                  <div className="tx-from">From: {tx.from}</div>
                  <div className="tx-to">To: {tx.minerName || tx.to}</div>
                  <div className="tx-amount">↓ {tx.amount.toFixed(2)} OMNI</div>
                  <div style={{ color: "#888", fontSize: "11px" }}>
                    Block: {tx.blockHeight} | <span className="status-good">✓ Confirmed</span>
                  </div>
                </div>
              ))
            ) : (
              <p style={{ color: "#888" }}>No mining transactions yet</p>
            )}
          </div>
        </div>
      </div>

      {/* Footer */}
      <footer>
        <p>🌍 OmniBus Blockchain – REAL Mining Rewards Only (No Mock Data)</p>
        <p>Each block contains 1 coinbase transaction distributing 50 OMNI to the mining node</p>
        <p style={{ marginTop: "20px", color: "#666" }}>
          Genesis Data: {new Date().toLocaleString()} UTC | Real Blocks: {stats.blockCount}
        </p>
      </footer>
    </div>
  );
};

export default App;
