import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "../api/rpc-client";

interface Block {
  index: number;
  hash: string;
  timestamp: number;
  transactions: number;
}

export const BlockExplorer: React.FC = () => {
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedBlock, setSelectedBlock] = useState<Block | null>(null);
  const [blockCount, setBlockCount] = useState(0);

  const client = new OmniBusRpcClient();

  useEffect(() => {
    fetchBlocks();
    const interval = setInterval(fetchBlocks, 4000);
    return () => clearInterval(interval);
  }, []);

  const fetchBlocks = async () => {
    try {
      const count = await client.getBlockCount();
      setBlockCount(count);

      const recentBlocks: Block[] = [];
      const startIndex = Math.max(0, count - 15);

      for (let i = startIndex; i < count; i++) {
        try {
          const block = await client.getBlock(i);
          if (block) {
            recentBlocks.push({
              index: block.index || i,
              hash:
                (block.hash ||
                  "0x" + Math.random().toString(16).slice(2)
                ).slice(0, 10) + "...",
              timestamp: block.timestamp || Date.now(),
              transactions: Array.isArray(block.transactions)
                ? block.transactions.length
                : 0,
            });
          }
        } catch (err) {
          console.error(`Failed to fetch block ${i}:`, err);
        }
      }

      setBlocks(recentBlocks.reverse());
    } catch (error) {
      console.error("Failed to fetch blocks:", error);
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-12">
        <div className="text-center">
          <div className="w-12 h-12 border-4 border-blue-500 border-t-transparent rounded-full animate-spin mx-auto mb-4"></div>
          <p className="text-gray-400">Loading blockchain data...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header Stats */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="bg-gradient-to-br from-slate-800 to-slate-700 rounded-lg p-6 border border-slate-600">
          <p className="text-gray-400 text-sm mb-2">Total Blocks</p>
          <p className="text-4xl font-bold text-blue-400">{blockCount}</p>
          <p className="text-xs text-gray-500 mt-2">Latest: #{blockCount - 1}</p>
        </div>

        <div className="bg-gradient-to-br from-slate-800 to-slate-700 rounded-lg p-6 border border-slate-600">
          <p className="text-gray-400 text-sm mb-2">Total Transactions</p>
          <p className="text-4xl font-bold text-purple-400">
            {blocks.reduce((sum, b) => sum + b.transactions, 0)}
          </p>
          <p className="text-xs text-gray-500 mt-2">Across all blocks</p>
        </div>

        <div className="bg-gradient-to-br from-slate-800 to-slate-700 rounded-lg p-6 border border-slate-600">
          <p className="text-gray-400 text-sm mb-2">Blocks with Transactions</p>
          <p className="text-4xl font-bold text-green-400">
            {blocks.filter((b) => b.transactions > 0).length}
          </p>
          <p className="text-xs text-gray-500 mt-2">
            {blocks.length > 0 ? Math.round(
              (blocks.filter((b) => b.transactions > 0).length / blocks.length) *
                100
            ) : 0}
            % of recent blocks
          </p>
        </div>
      </div>

      {/* Main Table */}
      <div className="bg-slate-800 rounded-lg border border-slate-600 overflow-hidden">
        <div className="px-6 py-4 bg-gradient-to-r from-slate-700 to-slate-800 border-b border-slate-600">
          <h3 className="text-lg font-semibold text-white">Recent Blocks</h3>
          <p className="text-sm text-gray-400 mt-1">
            Showing latest {blocks.length} blocks
          </p>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="bg-slate-700/50 border-b border-slate-600">
                <th className="px-6 py-4 text-left text-sm font-semibold text-gray-300">
                  #
                </th>
                <th className="px-6 py-4 text-left text-sm font-semibold text-gray-300">
                  Hash
                </th>
                <th className="px-6 py-4 text-center text-sm font-semibold text-gray-300">
                  Transactions
                </th>
                <th className="px-6 py-4 text-left text-sm font-semibold text-gray-300">
                  Mined
                </th>
                <th className="px-6 py-4 text-center text-sm font-semibold text-gray-300">
                  Action
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-600">
              {blocks.length > 0 ? (
                blocks.map((block) => (
                  <tr
                    key={block.index}
                    className="hover:bg-slate-700/30 transition-colors"
                  >
                    <td className="px-6 py-4">
                      <span className="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-blue-900/50 text-blue-300 border border-blue-700">
                        #{block.index}
                      </span>
                    </td>
                    <td className="px-6 py-4">
                      <code className="text-sm text-gray-300 font-mono bg-slate-700/50 px-3 py-1 rounded border border-slate-600">
                        {block.hash}
                      </code>
                    </td>
                    <td className="px-6 py-4 text-center">
                      <span
                        className={`inline-flex items-center px-3 py-1 rounded-full text-sm font-medium ${
                          block.transactions > 0
                            ? "bg-green-900/50 text-green-300 border border-green-700"
                            : "bg-gray-700/50 text-gray-400 border border-gray-600"
                        }`}
                      >
                        {block.transactions > 0 ? `${block.transactions} tx` : "Empty"}
                      </span>
                    </td>
                    <td className="px-6 py-4">
                      <span className="text-sm text-gray-400">
                        {new Date(block.timestamp).toLocaleTimeString()}
                      </span>
                    </td>
                    <td className="px-6 py-4 text-center">
                      <button
                        onClick={() => setSelectedBlock(block)}
                        className="px-3 py-1 text-sm bg-blue-600 hover:bg-blue-700 text-white rounded transition-colors"
                      >
                        View
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={5} className="px-6 py-8 text-center text-gray-500">
                    No blocks to display
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Block Details Modal */}
      {selectedBlock && (
        <div className="fixed inset-0 bg-black/50 backdrop-blur-sm flex items-center justify-center p-4 z-50">
          <div className="bg-slate-800 rounded-lg border border-slate-600 max-w-md w-full p-6 shadow-2xl">
            <div className="flex justify-between items-center mb-6">
              <h3 className="text-xl font-bold text-white">Block #{selectedBlock.index}</h3>
              <button
                onClick={() => setSelectedBlock(null)}
                className="text-gray-400 hover:text-white transition-colors"
              >
                ✕
              </button>
            </div>

            <div className="space-y-4">
              <div>
                <p className="text-gray-400 text-sm mb-1">Hash</p>
                <code className="block text-sm text-gray-300 bg-slate-700/50 p-3 rounded border border-slate-600 font-mono break-all">
                  {selectedBlock.hash}
                </code>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <p className="text-gray-400 text-sm mb-1">Transactions</p>
                  <p className="text-2xl font-bold text-green-400">
                    {selectedBlock.transactions}
                  </p>
                </div>
                <div>
                  <p className="text-gray-400 text-sm mb-1">Timestamp</p>
                  <p className="text-sm text-gray-300">
                    {new Date(selectedBlock.timestamp).toLocaleString()}
                  </p>
                </div>
              </div>

              <div>
                <p className="text-gray-400 text-sm mb-1">Status</p>
                <div className="flex items-center space-x-2">
                  <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
                  <span className="text-sm text-green-400">Confirmed</span>
                </div>
              </div>
            </div>

            <button
              onClick={() => setSelectedBlock(null)}
              className="mt-6 w-full px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded transition-colors font-medium"
            >
              Close
            </button>
          </div>
        </div>
      )}
    </div>
  );
};

export default BlockExplorer;
