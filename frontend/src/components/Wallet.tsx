import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "../api/rpc-client";

interface WalletAddress {
  name: string;
  algorithm: string;
  address: string;
}

export const Wallet: React.FC = () => {
  const [balance, setBalance] = useState<number>(0);
  const [loading, setLoading] = useState(true);
  const [copiedAddress, setCopiedAddress] = useState<string | null>(null);

  // Post-quantum cryptography addresses
  const addresses: WalletAddress[] = [
    {
      name: "Primary (OMNI)",
      algorithm: "Dilithium-5 + Kyber-768",
      address: "ob_omni_1q2w3e4r5t6y7u8i9o0p",
    },
    {
      name: "Secondary (Kyber)",
      algorithm: "Kyber-768 (256-bit)",
      address: "ob_k1_1a2s3d4f5g6h7j8k9l0z",
    },
    {
      name: "Tertiary (Falcon)",
      algorithm: "Falcon-512 (192-bit)",
      address: "ob_f5_1q2w3e4r5t6y7u8i9o0p",
    },
    {
      name: "Quaternary (Dilithium)",
      algorithm: "Dilithium-5 (256-bit)",
      address: "ob_d5_1a2s3d4f5g6h7j8k9l0z",
    },
    {
      name: "Quinary (SPHINCS+)",
      algorithm: "SPHINCS+ (128-bit)",
      address: "ob_s3_1q2w3e4r5t6y7u8i9o0p",
    },
  ];

  const client = new OmniBusRpcClient();

  useEffect(() => {
    fetchBalance();
    const interval = setInterval(fetchBalance, 5000);
    return () => clearInterval(interval);
  }, []);

  const fetchBalance = async () => {
    try {
      const bal = await client.getBalance();
      setBalance(bal);
    } catch (err) {
      console.error("Failed to fetch balance:", err);
    } finally {
      setLoading(false);
    }
  };

  const copyToClipboard = (address: string, name: string) => {
    navigator.clipboard.writeText(address);
    setCopiedAddress(name);
    setTimeout(() => setCopiedAddress(null), 2000);
  };

  const formatBalance = (sat: number) => {
    return (sat / 1e9).toFixed(2);
  };

  return (
    <div className="space-y-6">
      {/* Balance Card */}
      <div className="bg-gradient-to-br from-slate-800 via-slate-700 to-slate-800 rounded-lg border border-slate-600 overflow-hidden shadow-xl">
        <div className="px-6 py-8">
          <p className="text-gray-400 text-sm mb-3 uppercase tracking-wider font-semibold">
            Wallet Balance
          </p>
          {loading ? (
            <div className="animate-pulse">
              <div className="h-10 bg-slate-700 rounded w-48 mb-4"></div>
            </div>
          ) : (
            <>
              <div className="mb-6">
                <p className="text-5xl font-bold text-blue-400 mb-2">
                  {formatBalance(balance)}
                </p>
                <p className="text-xl text-gray-400">OMNI</p>
              </div>

              <div className="grid grid-cols-2 gap-4 pt-6 border-t border-slate-600">
                <div>
                  <p className="text-gray-500 text-sm mb-1">Total SAT</p>
                  <p className="text-lg font-mono text-gray-300">
                    {balance.toLocaleString()}
                  </p>
                </div>
                <div>
                  <p className="text-gray-500 text-sm mb-1">Status</p>
                  <div className="flex items-center space-x-2">
                    <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
                    <p className="text-lg text-green-400">Active</p>
                  </div>
                </div>
              </div>
            </>
          )}
        </div>
      </div>

      {/* Addresses Section */}
      <div className="bg-slate-800 rounded-lg border border-slate-600 overflow-hidden">
        <div className="px-6 py-4 bg-gradient-to-r from-slate-700 to-slate-800 border-b border-slate-600">
          <h3 className="text-lg font-semibold text-white">
            🔐 Post-Quantum Addresses
          </h3>
          <p className="text-sm text-gray-400 mt-1">
            5 NIST-approved cryptographic algorithms for maximum security
          </p>
        </div>

        <div className="divide-y divide-slate-600">
          {addresses.map((addr, idx) => (
            <div
              key={idx}
              className="px-6 py-5 hover:bg-slate-700/50 transition-colors"
            >
              <div className="flex items-start justify-between mb-4">
                <div>
                  <h4 className="text-white font-semibold text-base">
                    {addr.name}
                  </h4>
                  <p className="text-sm text-gray-400 mt-1">{addr.algorithm}</p>
                </div>
                <span className="px-3 py-1 bg-blue-900/50 text-blue-300 text-xs font-medium rounded-full border border-blue-700">
                  {["256-bit", "256-bit", "192-bit", "256-bit", "128-bit"][idx]}
                </span>
              </div>

              <div className="flex items-center space-x-2">
                <code className="flex-1 text-sm text-gray-300 bg-slate-900/50 px-4 py-2 rounded border border-slate-600 font-mono overflow-x-auto">
                  {addr.address}
                </code>
                <button
                  onClick={() => copyToClipboard(addr.address, addr.name)}
                  className={`px-4 py-2 rounded transition-colors font-medium text-sm whitespace-nowrap ${
                    copiedAddress === addr.name
                      ? "bg-green-600 text-white"
                      : "bg-slate-700 text-gray-300 hover:bg-slate-600"
                  }`}
                >
                  {copiedAddress === addr.name ? "✓ Copied" : "Copy"}
                </button>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Security Info */}
      <div className="bg-slate-800 rounded-lg border border-slate-600 p-6">
        <h3 className="text-lg font-semibold text-white mb-4">
          🛡️ Security Information
        </h3>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <h4 className="text-white font-medium mb-2">Cryptographic Algorithms</h4>
            <ul className="space-y-2 text-sm text-gray-400">
              <li className="flex items-center space-x-2">
                <span className="w-2 h-2 bg-blue-500 rounded-full"></span>
                <span>Dilithium-5: Digital signatures</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="w-2 h-2 bg-purple-500 rounded-full"></span>
                <span>Kyber-768: Key encapsulation</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="w-2 h-2 bg-pink-500 rounded-full"></span>
                <span>Falcon-512: Lattice-based</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="w-2 h-2 bg-green-500 rounded-full"></span>
                <span>SPHINCS+: Hash-based</span>
              </li>
            </ul>
          </div>

          <div>
            <h4 className="text-white font-medium mb-2">Wallet Features</h4>
            <ul className="space-y-2 text-sm text-gray-400">
              <li className="flex items-center space-x-2">
                <span className="text-green-400">✓</span>
                <span>Multi-algorithm support</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="text-green-400">✓</span>
                <span>Real-time balance sync</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="text-green-400">✓</span>
                <span>Deterministic derivation</span>
              </li>
              <li className="flex items-center space-x-2">
                <span className="text-green-400">✓</span>
                <span>Hardware-ready</span>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Wallet;
