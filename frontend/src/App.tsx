import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "./api/rpc-client";
import "./App.css";

type PageType = "dashboard" | "miners" | "blocks" | "distribution" | "network";

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
  const [currentPage, setCurrentPage] = useState<PageType>("dashboard");
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
      const statsData = await client.getBlockchainStats();
      setStats(statsData);

      const txData = await client.getTransactionHistory(50);
      setTransactions(txData);

      const minerData = await client.getMinerBalances();
      setMiners(minerData);

      if (statsData.blockCount > 0) {
        const recentBlocks: Block[] = [];
        const startIndex = Math.max(0, statsData.blockCount - 20);

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

  const getPageIcon = (page: PageType): string => {
    const icons = {
      dashboard: "📊",
      miners: "⛏️",
      blocks: "📦",
      distribution: "💰",
      network: "🔗",
    };
    return icons[page];
  };

  const getPageTitle = (page: PageType): string => {
    const titles = {
      dashboard: "Dashboard",
      miners: "Mining Nodes",
      blocks: "Blocks",
      distribution: "OMNI Distribution",
      network: "Network Stats",
    };
    return titles[page];
  };

  if (loading || !stats) {
    return (
      <div className="container" style={{ paddingTop: "100px", textAlign: "center" }}>
        <p style={{ color: "#888" }}>Loading blockchain data...</p>
      </div>
    );
  }

  return (
    <div>
      {/* Header */}
      <header style={{ background: "rgba(15, 15, 30, 0.95)", borderBottom: "2px solid #00ff88", padding: "20px 0", position: "sticky", top: 0, zIndex: 100 }}>
        <div className="container">
          <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
            <div>
              <h1 style={{ fontSize: "24px", color: "#00ff88", margin: 0 }}>⚡ OmniBus Explorer</h1>
              <p style={{ fontSize: "12px", color: "#888", margin: "5px 0 0 0" }}>Real-Time Mining & Distribution</p>
            </div>
            <div style={{ textAlign: "right" }}>
              <div style={{ color: "#00ff88", fontWeight: "bold" }}>Block #{stats.blockCount}</div>
              <div style={{ fontSize: "12px", color: "#888" }}>{miners.length} Active Miners</div>
            </div>
          </div>
        </div>
      </header>

      {/* Navigation */}
      <nav style={{ background: "rgba(30, 30, 45, 0.8)", borderBottom: "1px solid #333", padding: "0" }}>
        <div className="container" style={{ display: "flex", gap: 0 }}>
          {(["dashboard", "miners", "distribution", "blocks", "network"] as const).map((page) => (
            <button
              key={page}
              onClick={() => setCurrentPage(page)}
              style={{
                background: currentPage === page ? "rgba(0, 255, 136, 0.15)" : "transparent",
                border: `2px solid ${currentPage === page ? "#00ff88" : "transparent"}`,
                borderBottom: currentPage === page ? "3px solid #00ff88" : "1px solid #333",
                color: currentPage === page ? "#00ff88" : "#888",
                padding: "15px 20px",
                cursor: "pointer",
                fontSize: "13px",
                fontWeight: "bold",
                transition: "all 0.3s ease",
                flex: 1,
                textAlign: "center",
              }}
            >
              <span style={{ marginRight: "8px" }}>{getPageIcon(page)}</span>
              {getPageTitle(page)}
            </button>
          ))}
        </div>
      </nav>

      {/* Page Content */}
      <div className="container" style={{ minHeight: "600px" }}>
        {/* DASHBOARD PAGE */}
        {currentPage === "dashboard" && (
          <>
            <div style={{ marginTop: "30px", marginBottom: "30px" }}>
              <h2 style={{ color: "#00ff88", fontSize: "20px", marginBottom: "20px" }}>
                Dashboard Overview
              </h2>
              <div className="grid-3">
                <div className="section">
                  <div className="section-header">📊 Total Blocks</div>
                  <div className="section-body">
                    <div style={{ textAlign: "center" }}>
                      <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                        {stats.blockCount}
                      </div>
                      <div style={{ color: "#888", marginTop: "10px" }}>Blocks Mined</div>
                    </div>
                  </div>
                </div>

                <div className="section">
                  <div className="section-header">💰 Total Rewards</div>
                  <div className="section-body">
                    <div style={{ textAlign: "center" }}>
                      <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                        {formatBalance(stats.balance)}
                      </div>
                      <div style={{ color: "#888", marginTop: "10px" }}>OMNI Distributed</div>
                    </div>
                  </div>
                </div>

                <div className="section">
                  <div className="section-header">⛏️ Active Miners</div>
                  <div className="section-body">
                    <div style={{ textAlign: "center" }}>
                      <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                        {miners.length}
                      </div>
                      <div style={{ color: "#888", marginTop: "10px" }}>Mining Nodes</div>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div className="section">
              <div className="section-header">📈 Key Metrics</div>
              <div className="section-body">
                <div className="stat-grid">
                  <div className="stat-card">
                    <div className="stat-label">Reward Per Block</div>
                    <div className="stat-value">50 OMNI</div>
                  </div>
                  <div className="stat-card">
                    <div className="stat-label">Mining Transactions</div>
                    <div className="stat-value">{transactions.length}</div>
                  </div>
                  <div className="stat-card">
                    <div className="stat-label">Avg Blocks/Miner</div>
                    <div className="stat-value">
                      {miners.length > 0 ? (stats.blockCount / miners.length).toFixed(1) : "0"}
                    </div>
                  </div>
                  <div className="stat-card">
                    <div className="stat-label">Network Status</div>
                    <div className="stat-value status-good">✓ Active</div>
                  </div>
                </div>
              </div>
            </div>

            <div className="section" style={{ marginTop: "20px" }}>
              <div className="section-header">📦 Latest 5 Blocks</div>
              <div className="section-body">
                {blocks.slice(-5).reverse().map((block) => (
                  <div key={block.index} className="block-card">
                    <div className="block-title">Block #{block.index}</div>
                    <div className="block-detail">
                      <span className="block-detail-label">Miner:</span>
                      <span className="block-detail-value">{block.miner}</span>
                    </div>
                    <div className="block-detail">
                      <span className="block-detail-label">Reward:</span>
                      <span className="block-detail-value">{block.reward} OMNI</span>
                    </div>
                    <div className="block-detail">
                      <span className="block-detail-label">Time:</span>
                      <span className="block-detail-value">
                        {new Date(block.timestamp).toLocaleTimeString()}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </>
        )}

        {/* MINERS PAGE */}
        {currentPage === "miners" && (
          <>
            <div style={{ marginTop: "30px", marginBottom: "30px" }}>
              <h2 style={{ color: "#00ff88", fontSize: "20px", marginBottom: "20px" }}>
                Mining Nodes & Validators ({miners.length})
              </h2>

              <div className="section">
                <div className="section-header">⛏️ Active Miners - Balance Distribution</div>
                <div className="section-body">
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))", gap: "15px" }}>
                    {miners.map((miner, idx) => (
                      <div key={idx} className="address-card">
                        <div className="address-id">
                          {miner.minerName} (ID: {miner.minerID})
                        </div>
                        <div className="address-full" style={{ marginBottom: "10px" }}>
                          {miner.address}
                        </div>
                        <div style={{ background: "rgba(0, 255, 136, 0.1)", padding: "10px", borderRadius: "4px", marginBottom: "8px" }}>
                          <div style={{ color: "#00ff88", fontWeight: "bold", fontSize: "18px" }}>
                            {miner.balanceOmni.toFixed(2)} OMNI
                          </div>
                          <div style={{ color: "#888", fontSize: "11px", marginTop: "5px" }}>
                            Balance
                          </div>
                        </div>
                        <div style={{ color: "#888", fontSize: "11px" }}>
                          ⛏️ {miner.blocksMined} blocks mined
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
          </>
        )}

        {/* DISTRIBUTION PAGE */}
        {currentPage === "distribution" && (
          <>
            <div style={{ marginTop: "30px", marginBottom: "30px" }}>
              <h2 style={{ color: "#00ff88", fontSize: "20px", marginBottom: "20px" }}>
                OMNI Token Distribution
              </h2>

              <div className="grid-2">
                <div className="section">
                  <div className="section-header">💰 Distribution Summary</div>
                  <div className="section-body">
                    <div className="stat-card" style={{ marginBottom: "15px" }}>
                      <div className="stat-label">Total Distributed</div>
                      <div className="stat-value">{formatBalance(stats.balance)} OMNI</div>
                    </div>
                    <div className="stat-card" style={{ marginBottom: "15px" }}>
                      <div className="stat-label">Distribution Method</div>
                      <div style={{ color: "#e0e0e0", fontSize: "14px", marginTop: "8px" }}>
                        Block Mining Rewards
                      </div>
                    </div>
                    <div className="stat-card">
                      <div className="stat-label">Reward Per Block</div>
                      <div className="stat-value">50 OMNI</div>
                    </div>
                  </div>
                </div>

                <div className="section">
                  <div className="section-header">📊 Miner Distribution</div>
                  <div className="section-body">
                    {miners.map((miner, idx) => {
                      const percentage = stats.balance > 0 ? (miner.balanceOmni * 100) / (stats.balance / 1e9) : 0;
                      return (
                        <div key={idx} style={{ marginBottom: "15px" }}>
                          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: "5px" }}>
                            <span style={{ color: "#e0e0e0", fontSize: "12px" }}>{miner.minerName}</span>
                            <span style={{ color: "#00ff88", fontSize: "12px", fontWeight: "bold" }}>
                              {percentage.toFixed(1)}%
                            </span>
                          </div>
                          <div
                            style={{
                              background: "rgba(0, 0, 0, 0.3)",
                              height: "8px",
                              borderRadius: "4px",
                              overflow: "hidden",
                            }}
                          >
                            <div
                              style={{
                                background: "#00ff88",
                                height: "100%",
                                width: `${percentage}%`,
                                transition: "width 0.3s ease",
                              }}
                            />
                          </div>
                          <div style={{ color: "#888", fontSize: "10px", marginTop: "3px" }}>
                            {miner.balanceOmni.toFixed(2)} OMNI
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              </div>

              <div className="section" style={{ marginTop: "20px" }}>
                <div className="section-header">💸 Recent Mining Rewards (Last 10)</div>
                <div className="section-body">
                  {transactions.slice(0, 10).map((tx, idx) => (
                    <div key={idx} className="tx-card">
                      <div className="tx-from">From: {tx.from}</div>
                      <div className="tx-to">To: {tx.minerName || "Miner"}</div>
                      <div className="tx-amount">↓ {tx.amount.toFixed(2)} OMNI</div>
                      <div style={{ color: "#888", fontSize: "11px" }}>
                        Block #{tx.blockHeight} | <span className="status-good">✓ Confirmed</span>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </>
        )}

        {/* BLOCKS PAGE */}
        {currentPage === "blocks" && (
          <>
            <div style={{ marginTop: "30px", marginBottom: "30px" }}>
              <h2 style={{ color: "#00ff88", fontSize: "20px", marginBottom: "20px" }}>
                Block History ({blocks.length})
              </h2>

              <div className="section">
                <div className="section-header">📦 All Recent Blocks</div>
                <div className="section-body">
                  {blocks.map((block) => (
                    <div key={block.index} className="block-card">
                      <div className="block-title">Block #{block.index}</div>
                      <div className="block-detail">
                        <span className="block-detail-label">Hash:</span>
                        <span className="block-detail-value hash">{block.hash}</span>
                      </div>
                      <div className="block-detail">
                        <span className="block-detail-label">Miner:</span>
                        <span className="block-detail-value">{block.miner}</span>
                      </div>
                      <div className="block-detail">
                        <span className="block-detail-label">Reward:</span>
                        <span className="block-detail-value">{block.reward} OMNI</span>
                      </div>
                      <div className="block-detail">
                        <span className="block-detail-label">Transactions:</span>
                        <span className="block-detail-value">{block.transactions}</span>
                      </div>
                      <div className="block-detail">
                        <span className="block-detail-label">Time:</span>
                        <span className="block-detail-value">
                          {new Date(block.timestamp).toLocaleString()}
                        </span>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </>
        )}

        {/* NETWORK PAGE */}
        {currentPage === "network" && (
          <>
            <div style={{ marginTop: "30px", marginBottom: "30px" }}>
              <h2 style={{ color: "#00ff88", fontSize: "20px", marginBottom: "20px" }}>
                Network Statistics
              </h2>

              <div className="grid-3">
                <div className="section">
                  <div className="section-header">🔗 Total Nodes</div>
                  <div className="section-body">
                    <div style={{ textAlign: "center" }}>
                      <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                        {miners.length}
                      </div>
                      <div style={{ color: "#888", marginTop: "10px" }}>Mining Nodes</div>
                    </div>
                  </div>
                </div>

                <div className="section">
                  <div className="section-header">📡 Total Hashrate</div>
                  <div className="section-body">
                    <div style={{ textAlign: "center" }}>
                      <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                        {miners.length * 1000}
                      </div>
                      <div style={{ color: "#888", marginTop: "10px" }}>H/s</div>
                    </div>
                  </div>
                </div>

                <div className="section">
                  <div className="section-header">⚡ Block Time</div>
                  <div className="section-body">
                    <div style={{ textAlign: "center" }}>
                      <div style={{ fontSize: "48px", color: "#00ff88", fontWeight: "bold" }}>
                        ~2s
                      </div>
                      <div style={{ color: "#888", marginTop: "10px" }}>Average</div>
                    </div>
                  </div>
                </div>
              </div>

              <div className="section" style={{ marginTop: "20px" }}>
                <div className="section-header">🔗 Node Performance</div>
                <div className="section-body">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Miner</th>
                        <th>Blocks Mined</th>
                        <th>Balance (OMNI)</th>
                        <th>Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {miners.map((miner, idx) => (
                        <tr key={idx}>
                          <td style={{ color: "#ff00ff" }}>{miner.minerName}</td>
                          <td>{miner.blocksMined}</td>
                          <td style={{ color: "#00ff88" }}>{miner.balanceOmni.toFixed(2)}</td>
                          <td>
                            <span className="status-good">✓ Active</span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </>
        )}
      </div>

      {/* Footer */}
      <footer style={{ marginTop: "40px" }}>
        <p>🌍 OmniBus Blockchain – Real Mining & Distribution</p>
        <p>Each block = 1 mining reward transaction | 50 OMNI per block distributed to miners</p>
        <p style={{ marginTop: "20px", color: "#666" }}>
          Data: {new Date().toLocaleString()} UTC
        </p>
      </footer>
    </div>
  );
};

export default App;
