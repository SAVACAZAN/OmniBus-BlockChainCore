import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "../api/rpc-client";

interface ChainStats {
  blockCount: number;
  mempoolSize: number;
  balance: number;
}

export const Stats: React.FC = () => {
  const [stats, setStats] = useState<ChainStats | null>(null);
  const [loading, setLoading] = useState(true);

  const client = new OmniBusRpcClient();

  useEffect(() => {
    fetchStats();
    const interval = setInterval(fetchStats, 5000);
    return () => clearInterval(interval);
  }, []);

  const fetchStats = async () => {
    try {
      const data = await client.getBlockchainStats();
      setStats(data);
    } catch (error) {
      console.error("Failed to fetch stats:", error);
    } finally {
      setLoading(false);
    }
  };

  if (loading || !stats) {
    return <div className="text-gray-500">Loading...</div>;
  }

  return (
    <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
      {/* Total Blocks */}
      <div className="bg-white rounded-lg shadow p-6">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-gray-600 text-sm font-medium">Total Blocks</p>
            <p className="text-3xl font-bold text-gray-900 mt-2">
              {stats.blockCount}
            </p>
          </div>
          <div className="p-3 bg-blue-100 rounded-full">
            <svg
              className="w-6 h-6 text-blue-600"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path d="M3 4a1 1 0 011-1h12a1 1 0 011 1v2a1 1 0 01-1 1H4a1 1 0 01-1-1V4z" />
              <path d="M3 10a1 1 0 011-1h12a1 1 0 011 1v6a1 1 0 01-1 1H4a1 1 0 01-1-1v-6z" />
            </svg>
          </div>
        </div>
      </div>

      {/* Mempool Size */}
      <div className="bg-white rounded-lg shadow p-6">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-gray-600 text-sm font-medium">
              Pending Transactions
            </p>
            <p className="text-3xl font-bold text-gray-900 mt-2">
              {stats.mempoolSize}
            </p>
          </div>
          <div className="p-3 bg-orange-100 rounded-full">
            <svg
              className="w-6 h-6 text-orange-600"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path d="M2 11a1 1 0 011-1h2a1 1 0 011 1v5a1 1 0 01-1 1H3a1 1 0 01-1-1v-5z" />
              <path d="M8 7a1 1 0 011-1h2a1 1 0 011 1v9a1 1 0 01-1 1H9a1 1 0 01-1-1V7z" />
              <path d="M14 4a1 1 0 011-1h2a1 1 0 011 1v12a1 1 0 01-1 1h-2a1 1 0 01-1-1V4z" />
            </svg>
          </div>
        </div>
      </div>

      {/* Wallet Balance */}
      <div className="bg-white rounded-lg shadow p-6">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-gray-600 text-sm font-medium">Balance</p>
            <p className="text-3xl font-bold text-gray-900 mt-2">
              {(stats.balance / 1e18).toFixed(6)} OMNI
            </p>
          </div>
          <div className="p-3 bg-green-100 rounded-full">
            <svg
              className="w-6 h-6 text-green-600"
              fill="currentColor"
              viewBox="0 0 20 20"
            >
              <path d="M4 4a2 2 0 00-2 2v4a2 2 0 002 2V6h10a2 2 0 00-2-2H4z" />
              <path d="M18 9a2 2 0 002-2V3a2 2 0 00-2-2h-5a2 2 0 00-2 2v4a2 2 0 002 2h5z" />
              <path d="M4 12a2 2 0 00-2 2v4a2 2 0 002 2h5a2 2 0 002-2v-4a2 2 0 00-2-2H4z" />
            </svg>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Stats;
