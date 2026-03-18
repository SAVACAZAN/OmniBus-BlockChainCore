import React, { useState, useEffect } from 'react';
import { AlertCircle, CheckCircle, Zap, Cpu, Network, Play } from 'lucide-react';

interface Miner {
  id: number;
  name: string;
  status: 'offline' | 'connecting' | 'mining' | 'block_found' | 'error';
  isConnected: boolean;
  blocksMined: number;
  sharesSubmitted: number;
  sharesAccepted: number;
  hashrate: number;
  uptime: number;
}

interface BlockchainStatus {
  status: 'initializing' | 'waiting' | 'ready' | 'mining' | 'error';
  blockCount: number;
  currentDifficulty: number;
  timestamp: number;
  connectedMiners: number;
  totalMiners: number;
  totalHashrate: number;
  genesisReady: boolean;
  genesisStarted: boolean;
  minersRequired: number;
}

const GenesisCountdown: React.FC = () => {
  const [blockchainStatus, setBlockchainStatus] = useState<BlockchainStatus>({
    status: 'initializing',
    blockCount: 0,
    currentDifficulty: 4,
    timestamp: Date.now(),
    connectedMiners: 0,
    totalMiners: 0,
    totalHashrate: 0,
    genesisReady: false,
    genesisStarted: false,
    minersRequired: 3,
  });

  const [miners, setMiners] = useState<Miner[]>([]);
  const [showLaunchMiners, setShowLaunchMiners] = useState(false);
  const [genesisCountdown, setGenesisCountdown] = useState(0);

  // Fetch blockchain status
  useEffect(() => {
    const fetchStatus = async () => {
      try {
        const response = await fetch('http://localhost:8332', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            jsonrpc: '2.0',
            method: 'getGenesisStatus',
            params: [],
            id: 1,
          }),
        });
        const data = await response.json();
        if (data.result) {
          setBlockchainStatus(data.result);
        }
      } catch (error) {
        console.error('Failed to fetch status:', error);
      }
    };

    fetchStatus();
    const interval = setInterval(fetchStatus, 2000);
    return () => clearInterval(interval);
  }, []);

  // Fetch miners
  useEffect(() => {
    const fetchMiners = async () => {
      try {
        const response = await fetch('http://localhost:8332', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            jsonrpc: '2.0',
            method: 'getMiners',
            params: [],
            id: 1,
          }),
        });
        const data = await response.json();
        if (Array.isArray(data.result)) {
          setMiners(data.result);
        }
      } catch (error) {
        console.error('Failed to fetch miners:', error);
      }
    };

    fetchMiners();
    const interval = setInterval(fetchMiners, 3000);
    return () => clearInterval(interval);
  }, []);

  // Countdown timer
  useEffect(() => {
    if (blockchainStatus.genesisReady && !blockchainStatus.genesisStarted) {
      const countdown = blockchainStatus.minersRequired - blockchainStatus.connectedMiners;
      setGenesisCountdown(countdown);
    }
  }, [blockchainStatus]);

  const handleStartGenesis = async () => {
    try {
      const response = await fetch('http://localhost:8332', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: 'startGenesis',
          params: [],
          id: 1,
        }),
      });
      const data = await response.json();
      if (data.result) {
        alert('Genesis started!');
      }
    } catch (error) {
      console.error('Failed to start genesis:', error);
      alert('Error starting genesis');
    }
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'mining':
      case 'block_found':
        return 'bg-green-100 text-green-800';
      case 'connecting':
        return 'bg-yellow-100 text-yellow-800';
      case 'offline':
      case 'error':
        return 'bg-red-100 text-red-800';
      default:
        return 'bg-gray-100 text-gray-800';
    }
  };

  const getStatusIcon = (status: string) => {
    switch (status) {
      case 'mining':
        return <Zap className="w-4 h-4" />;
      case 'block_found':
        return <CheckCircle className="w-4 h-4" />;
      case 'connecting':
        return <Network className="w-4 h-4" />;
      default:
        return <AlertCircle className="w-4 h-4" />;
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-900 to-slate-800 text-white p-8">
      <div className="max-w-6xl mx-auto">
        {/* Header */}
        <div className="mb-8">
          <h1 className="text-5xl font-bold mb-2 flex items-center gap-3">
            <Zap className="w-12 h-12 text-yellow-400" />
            Genesis Countdown
          </h1>
          <p className="text-gray-400">OmniBus Blockchain Network Initialization</p>
        </div>

        {/* Main Status Card */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-8">
          {/* Blockchain Status */}
          <div className="bg-slate-700 rounded-lg p-6 col-span-1 lg:col-span-1">
            <h2 className="text-xl font-bold mb-4 flex items-center gap-2">
              <Network className="w-5 h-5 text-blue-400" />
              Blockchain Status
            </h2>
            <div className="space-y-3">
              <div>
                <p className="text-gray-400 text-sm">Network Status</p>
                <p className="text-2xl font-bold capitalize">{blockchainStatus.status}</p>
              </div>
              <div>
                <p className="text-gray-400 text-sm">Block Height</p>
                <p className="text-2xl font-bold">{blockchainStatus.blockCount}</p>
              </div>
              <div>
                <p className="text-gray-400 text-sm">Difficulty</p>
                <p className="text-lg font-mono">{blockchainStatus.currentDifficulty}</p>
              </div>
            </div>
          </div>

          {/* Miner Status */}
          <div className="bg-slate-700 rounded-lg p-6 col-span-1 lg:col-span-1">
            <h2 className="text-xl font-bold mb-4 flex items-center gap-2">
              <Cpu className="w-5 h-5 text-purple-400" />
              Miners Connected
            </h2>
            <div className="space-y-3">
              <div>
                <p className="text-gray-400 text-sm">Connected / Total</p>
                <p className="text-2xl font-bold">
                  {blockchainStatus.connectedMiners}/{blockchainStatus.totalMiners}
                </p>
              </div>
              <div>
                <p className="text-gray-400 text-sm">Total Hashrate</p>
                <p className="text-xl font-mono">{blockchainStatus.totalHashrate} H/s</p>
              </div>
              <div>
                <p className="text-gray-400 text-sm">Min. Required</p>
                <p className="text-lg">{blockchainStatus.minersRequired}</p>
              </div>
            </div>
          </div>

          {/* Genesis Status */}
          <div className={`rounded-lg p-6 col-span-1 lg:col-span-1 ${
            blockchainStatus.genesisReady ? 'bg-green-900' : 'bg-slate-700'
          }`}>
            <h2 className="text-xl font-bold mb-4 flex items-center gap-2">
              <CheckCircle className={`w-5 h-5 ${blockchainStatus.genesisReady ? 'text-green-400' : 'text-gray-400'}`} />
              Genesis Ready
            </h2>
            <div className="space-y-3">
              <div>
                <p className="text-gray-300 text-sm">Status</p>
                <p className={`text-2xl font-bold ${blockchainStatus.genesisReady ? 'text-green-400' : 'text-gray-400'}`}>
                  {blockchainStatus.genesisReady ? '✓ Ready' : '⏳ Waiting'}
                </p>
              </div>
              {blockchainStatus.genesisReady && !blockchainStatus.genesisStarted && (
                <button
                  onClick={handleStartGenesis}
                  className="w-full bg-green-600 hover:bg-green-700 text-white font-bold py-2 px-4 rounded-lg flex items-center justify-center gap-2 transition-colors"
                >
                  <Play className="w-4 h-4" />
                  Start Genesis
                </button>
              )}
              {blockchainStatus.genesisStarted && (
                <p className="text-green-300 text-sm font-semibold">🎉 Genesis Mining Started!</p>
              )}
            </div>
          </div>
        </div>

        {/* Miners Grid */}
        <div className="bg-slate-700 rounded-lg p-6 mb-8">
          <div className="flex items-center justify-between mb-6">
            <h2 className="text-2xl font-bold flex items-center gap-2">
              <Cpu className="w-6 h-6 text-purple-400" />
              Active Miners ({miners.length})
            </h2>
            <button
              onClick={() => setShowLaunchMiners(!showLaunchMiners)}
              className="bg-purple-600 hover:bg-purple-700 text-white font-bold py-2 px-4 rounded-lg transition-colors"
            >
              {showLaunchMiners ? 'Hide Launch' : 'Launch Miners'}
            </button>
          </div>

          {/* Launch Multiple Miners */}
          {showLaunchMiners && (
            <div className="bg-slate-600 rounded-lg p-4 mb-6">
              <h3 className="font-bold mb-4">Launch Light Miners (Windows)</h3>
              <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
                {[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((num) => (
                  <button
                    key={num}
                    className="bg-blue-600 hover:bg-blue-700 text-white py-2 px-3 rounded-lg text-sm font-bold transition-colors"
                    onClick={() => {
                      alert(`Launching light-miner-${num} instance...`);
                      // In real implementation: spawn miner process
                    }}
                  >
                    Miner {num}
                  </button>
                ))}
              </div>
              <p className="text-gray-400 text-sm mt-4">
                💡 Click a button to launch a light miner instance on Windows. You can run all 10 simultaneously.
              </p>
            </div>
          )}

          {/* Miners List */}
          {miners.length === 0 ? (
            <div className="text-center py-8 text-gray-400">
              <p>No miners connected yet</p>
              <p className="text-sm mt-2">Click "Launch Miners" to start mining instances</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {miners.map((miner) => (
                <div
                  key={miner.id}
                  className={`rounded-lg p-4 border-2 transition-colors ${
                    miner.isConnected
                      ? 'border-green-500 bg-green-950'
                      : 'border-gray-600 bg-slate-600'
                  }`}
                >
                  <div className="flex items-center justify-between mb-3">
                    <h3 className="font-bold text-lg">{miner.name}</h3>
                    <span
                      className={`px-3 py-1 rounded-full text-xs font-bold flex items-center gap-1 ${getStatusColor(miner.status)}`}
                    >
                      {getStatusIcon(miner.status)}
                      {miner.status.replace('_', ' ')}
                    </span>
                  </div>

                  <div className="space-y-2 text-sm">
                    <div className="flex justify-between">
                      <span className="text-gray-400">Blocks Mined:</span>
                      <span className="font-bold">{miner.blocksMined}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-400">Hashrate:</span>
                      <span className="font-mono">{miner.hashrate} H/s</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-400">Shares:</span>
                      <span className="font-mono">
                        {miner.sharesAccepted}/{miner.sharesSubmitted}
                      </span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-400">Uptime:</span>
                      <span className="font-mono">{miner.uptime}s</span>
                    </div>
                  </div>

                  {/* Progress bar */}
                  <div className="mt-3 bg-slate-500 rounded-full h-2 overflow-hidden">
                    <div
                      className={`h-full ${
                        miner.isConnected ? 'bg-green-500' : 'bg-gray-500'
                      } transition-all`}
                      style={{
                        width: `${
                          miner.sharesSubmitted > 0
                            ? (miner.sharesAccepted / miner.sharesSubmitted) * 100
                            : 0
                        }%`,
                      }}
                    />
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Statistics Footer */}
        <div className="bg-slate-700 rounded-lg p-6">
          <h2 className="text-xl font-bold mb-4">Network Statistics</h2>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <p className="text-gray-400 text-sm">Avg. Hashrate</p>
              <p className="text-2xl font-bold">
                {miners.length > 0
                  ? Math.round(blockchainStatus.totalHashrate / miners.length)
                  : 0}{' '}
                H/s
              </p>
            </div>
            <div>
              <p className="text-gray-400 text-sm">Genesis Progress</p>
              <p className="text-2xl font-bold">
                {blockchainStatus.genesisStarted ? '100%' : blockchainStatus.genesisReady ? '75%' : '25%'}
              </p>
            </div>
            <div>
              <p className="text-gray-400 text-sm">Est. Start Time</p>
              <p className="text-lg font-mono">
                {blockchainStatus.genesisStarted
                  ? 'Now'
                  : blockchainStatus.genesisReady
                    ? '<1 min'
                    : 'Waiting...'}
              </p>
            </div>
            <div>
              <p className="text-gray-400 text-sm">Network Time</p>
              <p className="text-lg font-mono">
                {new Date(blockchainStatus.timestamp).toLocaleTimeString()}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default GenesisCountdown;
