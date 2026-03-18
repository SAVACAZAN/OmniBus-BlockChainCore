import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "../api/rpc-client";

interface Block {
  index: number;
  timestamp: number;
  transactions: any[];
  previous_hash: string;
  nonce: number;
  hash: string;
}

export const BlockExplorer: React.FC = () => {
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedBlock, setSelectedBlock] = useState<Block | null>(null);

  const client = new OmniBusRpcClient();

  useEffect(() => {
    fetchBlocks();
    const interval = setInterval(fetchBlocks, 10000); // Refresh every 10 seconds
    return () => clearInterval(interval);
  }, []);

  const fetchBlocks = async () => {
    try {
      setLoading(true);
      const recentBlocks = await client.getRecentBlocks(20);
      setBlocks(recentBlocks);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to fetch blocks");
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return (
      <div className="flex justify-center items-center h-96">
        <div className="animate-spin rounded-full h-12 w-12 border-t-2 border-b-2 border-blue-500"></div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4">
        <p className="text-red-600">Error: {error}</p>
        <button
          onClick={fetchBlocks}
          className="mt-2 px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700"
        >
          Retry
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex justify-between items-center">
        <h2 className="text-2xl font-bold text-gray-900">Block Explorer</h2>
        <button
          onClick={fetchBlocks}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition"
        >
          Refresh
        </button>
      </div>

      {selectedBlock ? (
        <div className="bg-white rounded-lg shadow-lg p-6">
          <button
            onClick={() => setSelectedBlock(null)}
            className="text-blue-600 hover:text-blue-800 mb-4"
          >
            ← Back to list
          </button>

          <h3 className="text-xl font-bold mb-4">
            Block #{selectedBlock.index}
          </h3>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <p className="text-gray-600 text-sm">Timestamp</p>
              <p className="font-mono text-sm">
                {new Date(selectedBlock.timestamp * 1000).toLocaleString()}
              </p>
            </div>

            <div>
              <p className="text-gray-600 text-sm">Nonce</p>
              <p className="font-mono text-sm">{selectedBlock.nonce}</p>
            </div>

            <div className="col-span-2">
              <p className="text-gray-600 text-sm">Hash</p>
              <p className="font-mono text-xs break-all">
                {selectedBlock.hash}
              </p>
            </div>

            <div className="col-span-2">
              <p className="text-gray-600 text-sm">Previous Hash</p>
              <p className="font-mono text-xs break-all">
                {selectedBlock.previous_hash}
              </p>
            </div>

            <div className="col-span-2">
              <p className="text-gray-600 text-sm">Transactions</p>
              <p className="font-mono">
                {selectedBlock.transactions.length} transaction
                {selectedBlock.transactions.length !== 1 ? "s" : ""}
              </p>
            </div>
          </div>
        </div>
      ) : (
        <div className="bg-white rounded-lg shadow overflow-hidden">
          <table className="w-full">
            <thead className="bg-gray-50 border-b">
              <tr>
                <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">
                  Height
                </th>
                <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">
                  Timestamp
                </th>
                <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">
                  Transactions
                </th>
                <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">
                  Hash
                </th>
                <th className="px-6 py-3 text-right text-sm font-semibold text-gray-900">
                  Action
                </th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {blocks.map((block) => (
                <tr key={block.index} className="hover:bg-gray-50">
                  <td className="px-6 py-4 text-sm font-medium text-gray-900">
                    #{block.index}
                  </td>
                  <td className="px-6 py-4 text-sm text-gray-600">
                    {new Date(block.timestamp * 1000).toLocaleString()}
                  </td>
                  <td className="px-6 py-4 text-sm text-gray-600">
                    {block.transactions.length}
                  </td>
                  <td className="px-6 py-4 text-sm font-mono text-gray-600 truncate max-w-xs">
                    {block.hash.substring(0, 16)}...
                  </td>
                  <td className="px-6 py-4 text-right text-sm">
                    <button
                      onClick={() => setSelectedBlock(block)}
                      className="text-blue-600 hover:text-blue-800"
                    >
                      View
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
};

export default BlockExplorer;
