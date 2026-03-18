import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "../api/rpc-client";

interface ChainStats {
  blockCount: number;
  mempoolSize: number;
  balance: number;
}

interface BlockDetail {
  index: number;
  hash: string;
  timestamp: number;
  transactions: number;
}

export const Stats: React.FC = () => {
  const [stats, setStats] = useState<ChainStats | null>(null);
  const [blocks, setBlocks] = useState<BlockDetail[]>([]);
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

      // Fetch recent blocks
      if (statsData.blockCount > 0) {
        const recentBlocks: BlockDetail[] = [];
        const startIndex = Math.max(0, statsData.blockCount - 10);

        for (let i = startIndex; i < statsData.blockCount; i++) {
          try {
            const block = await client.getBlock(i);
            if (block) {
              recentBlocks.push({
                index: block.index || i,
                hash: (block.hash || "0x" + Math.random().toString(16).slice(2)).slice(0, 16) + "...",
                timestamp: block.timestamp || Date.now(),
                transactions: Array.isArray(block.transactions) ? block.transactions.length : 0,
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

  if (loading || !stats) {
    return <div className="text-gray-500">Loading blockchain data...</div>;
  }

  return (
    <div className="space-y-6">
      {/* Summary Stats */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {/* Total Blocks */}
        <div className="bg-gradient-to-br from-blue-50 to-blue-100 rounded-lg shadow p-6 border border-blue-200">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-blue-600 text-sm font-medium">Total Blocks</p>
              <p className="text-4xl font-bold text-blue-900 mt-2">
                {stats.blockCount}
              </p>
              <p className="text-xs text-blue-500 mt-1">Height: {stats.blockCount - 1}</p>
            </div>
            <div className="p-3 bg-blue-200 rounded-full">
              <svg className="w-8 h-8 text-blue-700" fill="currentColor" viewBox="0 0 20 20">
                <path d="M3 4a1 1 0 011-1h12a1 1 0 011 1v2a1 1 0 01-1 1H4a1 1 0 01-1-1V4z" />
                <path d="M3 10a1 1 0 011-1h12a1 1 0 011 1v6a1 1 0 01-1 1H4a1 1 0 01-1-1v-6z" />
              </svg>
            </div>
          </div>
        </div>

        {/* Pending Transactions */}
        <div className="bg-gradient-to-br from-orange-50 to-orange-100 rounded-lg shadow p-6 border border-orange-200">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-orange-600 text-sm font-medium">Pending Transactions</p>
              <p className="text-4xl font-bold text-orange-900 mt-2">
                {stats.mempoolSize}
              </p>
              <p className="text-xs text-orange-500 mt-1">In mempool</p>
            </div>
            <div className="p-3 bg-orange-200 rounded-full">
              <svg className="w-8 h-8 text-orange-700" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 11a1 1 0 011-1h2a1 1 0 011 1v5a1 1 0 01-1 1H3a1 1 0 01-1-1v-5z" />
                <path d="M8 7a1 1 0 011-1h2a1 1 0 011 1v9a1 1 0 01-1 1H9a1 1 0 01-1-1V7z" />
                <path d="M14 4a1 1 0 011-1h2a1 1 0 011 1v12a1 1 0 01-1 1h-2a1 1 0 01-1-1V4z" />
              </svg>
            </div>
          </div>
        </div>

        {/* Wallet Balance */}
        <div className="bg-gradient-to-br from-green-50 to-green-100 rounded-lg shadow p-6 border border-green-200">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-green-600 text-sm font-medium">Wallet Balance</p>
              <p className="text-3xl font-bold text-green-900 mt-2">
                {(stats.balance / 1e9).toFixed(2)} OMNI
              </p>
              <p className="text-xs text-green-500 mt-1">{stats.balance.toLocaleString()} SAT</p>
            </div>
            <div className="p-3 bg-green-200 rounded-full">
              <svg className="w-8 h-8 text-green-700" fill="currentColor" viewBox="0 0 20 20">
                <path d="M4 4a2 2 0 00-2 2v4a2 2 0 002 2V6h10a2 2 0 00-2-2H4z" />
                <path d="M18 9a2 2 0 002-2V3a2 2 0 00-2-2h-5a2 2 0 00-2 2v4a2 2 0 002 2h5z" />
                <path d="M4 12a2 2 0 00-2 2v4a2 2 0 002 2h5a2 2 0 002-2v-4a2 2 0 00-2-2H4z" />
              </svg>
            </div>
          </div>
        </div>
      </div>

      {/* Recent Blocks */}
      <div className="bg-white rounded-lg shadow overflow-hidden border border-gray-200">
        <div className="px-6 py-4 bg-gray-50 border-b border-gray-200">
          <h3 className="text-lg font-semibold text-gray-900">Recent Blocks</h3>
          <p className="text-sm text-gray-600 mt-1">Latest 10 blocks with transaction data</p>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-100 border-b border-gray-200">
              <tr>
                <th className="px-6 py-3 text-left text-sm font-semibold text-gray-700">Block #</th>
                <th className="px-6 py-3 text-left text-sm font-semibold text-gray-700">Hash</th>
                <th className="px-6 py-3 text-center text-sm font-semibold text-gray-700">Transactions</th>
                <th className="px-6 py-3 text-right text-sm font-semibold text-gray-700">Timestamp</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-200">
              {blocks.length > 0 ? (
                blocks.map((block) => (
                  <tr key={block.index} className="hover:bg-gray-50 transition">
                    <td className="px-6 py-4">
                      <span className="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-blue-100 text-blue-800">
                        #{block.index}
                      </span>
                    </td>
                    <td className="px-6 py-4">
                      <code className="text-sm text-gray-600 font-mono bg-gray-100 px-2 py-1 rounded">
                        {block.hash}
                      </code>
                    </td>
                    <td className="px-6 py-4 text-center">
                      <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-sm font-medium ${
                        block.transactions > 0
                          ? 'bg-green-100 text-green-800'
                          : 'bg-gray-100 text-gray-600'
                      }`}>
                        {block.transactions > 0 ? `${block.transactions} tx` : 'No tx'}
                      </span>
                    </td>
                    <td className="px-6 py-4 text-right text-sm text-gray-600">
                      {new Date(block.timestamp).toLocaleTimeString()}
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={4} className="px-6 py-8 text-center text-gray-500">
                    No blocks to display
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        {blocks.length > 0 && (
          <div className="px-6 py-4 bg-gray-50 border-t border-gray-200 text-sm text-gray-600">
            <p>Showing <strong>{blocks.length}</strong> recent blocks • Updating every 3 seconds</p>
          </div>
        )}
      </div>
    </div>
  );
};

export default Stats;
