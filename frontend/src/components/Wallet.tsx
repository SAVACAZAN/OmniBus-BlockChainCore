import React, { useState, useEffect } from "react";
import OmniBusRpcClient from "../api/rpc-client";

interface WalletAddress {
  domain: string;
  algorithm: string;
  address: string;
  erc20_address: string;
  security_level: number;
}

export const Wallet: React.FC = () => {
  const [balance, setBalance] = useState<number>(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sendAmount, setSendAmount] = useState("");
  const [sendTo, setSendTo] = useState("");
  const [sending, setSending] = useState(false);
  const [txHash, setTxHash] = useState<string | null>(null);

  // Mock addresses - in production, would come from wallet system
  const addresses: WalletAddress[] = [
    {
      domain: "omnibus.omni",
      algorithm: "Dilithium-5 + Kyber-768",
      address: "ob_omni_1q2w3e4r5t6y7u8i9o0p",
      erc20_address: "0x8ba1f109551bD432803012645Ac136ddd64DBA72",
      security_level: 256,
    },
    {
      domain: "omnibus.love",
      algorithm: "Kyber-768",
      address: "ob_k1_1a2s3d4f5g6h7j8k9l0z",
      erc20_address: "0x8ba1f109551bD432803012645Ac136ddd64DBA72",
      security_level: 256,
    },
    {
      domain: "omnibus.food",
      algorithm: "Falcon-512",
      address: "ob_f5_1q2w3e4r5t6y7u8i9o0p",
      erc20_address: "0x8ba1f109551bD432803012645Ac136ddd64DBA72",
      security_level: 192,
    },
    {
      domain: "omnibus.rent",
      algorithm: "Dilithium-5",
      address: "ob_d5_1a2s3d4f5g6h7j8k9l0z",
      erc20_address: "0x8ba1f109551bD432803012645Ac136ddd64DBA72",
      security_level: 256,
    },
    {
      domain: "omnibus.vacation",
      algorithm: "SPHINCS+",
      address: "ob_s3_1q2w3e4r5t6y7u8i9o0p",
      erc20_address: "0x8ba1f109551bD432803012645Ac136ddd64DBA72",
      security_level: 128,
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
      setLoading(true);
      const bal = await client.getBalance();
      setBalance(bal);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to fetch balance");
    } finally {
      setLoading(false);
    }
  };

  const handleSend = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!sendTo || !sendAmount) {
      setError("Please fill in all fields");
      return;
    }

    try {
      setSending(true);
      setError(null);
      const hash = await client.sendTransaction(sendTo, parseFloat(sendAmount));
      setTxHash(hash);
      setSendAmount("");
      setSendTo("");
      setTimeout(() => setTxHash(null), 5000);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Transaction failed");
    } finally {
      setSending(false);
    }
  };

  const formatBalance = (satoshis: number) => {
    const omni = satoshis / 1e18;
    return omni.toFixed(6);
  };

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-bold text-gray-900 mb-4">Wallet</h2>

        {/* Balance Card */}
        <div className="bg-gradient-to-r from-blue-600 to-blue-800 rounded-lg shadow-lg p-6 text-white mb-6">
          <p className="text-blue-100 text-sm mb-2">Total Balance</p>
          {loading ? (
            <p className="text-3xl font-bold">Loading...</p>
          ) : (
            <>
              <p className="text-3xl font-bold">
                {formatBalance(balance)} OMNI
              </p>
              <p className="text-blue-100 text-sm mt-2">
                {balance.toLocaleString()} SAT
              </p>
            </>
          )}
        </div>

        {error && (
          <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
            <p className="text-red-600 text-sm">{error}</p>
          </div>
        )}

        {txHash && (
          <div className="bg-green-50 border border-green-200 rounded-lg p-4 mb-6">
            <p className="text-green-600 text-sm">
              Transaction sent! Hash: {txHash}
            </p>
          </div>
        )}
      </div>

      {/* Send Transaction Form */}
      <div className="bg-white rounded-lg shadow-lg p-6">
        <h3 className="text-lg font-bold text-gray-900 mb-4">Send Transaction</h3>

        <form onSubmit={handleSend} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              Recipient Address
            </label>
            <input
              type="text"
              value={sendTo}
              onChange={(e) => setSendTo(e.target.value)}
              placeholder="ob_omni_..."
              className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 outline-none"
              disabled={sending}
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              Amount (OMNI)
            </label>
            <input
              type="number"
              value={sendAmount}
              onChange={(e) => setSendAmount(e.target.value)}
              placeholder="0.000000"
              step="0.000001"
              min="0"
              className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 outline-none"
              disabled={sending}
            />
          </div>

          <button
            type="submit"
            disabled={sending}
            className="w-full px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 transition font-medium"
          >
            {sending ? "Sending..." : "Send"}
          </button>
        </form>
      </div>

      {/* Addresses */}
      <div className="bg-white rounded-lg shadow-lg p-6">
        <h3 className="text-lg font-bold text-gray-900 mb-4">
          Post-Quantum Addresses
        </h3>

        <div className="space-y-4">
          {addresses.map((addr, idx) => (
            <div key={idx} className="border border-gray-200 rounded-lg p-4">
              <div className="flex justify-between items-start mb-2">
                <div>
                  <p className="font-semibold text-gray-900">{addr.domain}</p>
                  <p className="text-sm text-gray-600">{addr.algorithm}</p>
                </div>
                <span className="px-2 py-1 bg-blue-100 text-blue-800 text-xs font-semibold rounded">
                  {addr.security_level}-bit
                </span>
              </div>

              <div className="space-y-2">
                <div>
                  <p className="text-xs text-gray-600 mb-1">OMNI Address:</p>
                  <p className="font-mono text-xs break-all bg-gray-50 p-2 rounded">
                    {addr.address}
                  </p>
                </div>

                <div>
                  <p className="text-xs text-gray-600 mb-1">
                    ERC20 Address (Ethereum):
                  </p>
                  <p className="font-mono text-xs break-all bg-gray-50 p-2 rounded">
                    {addr.erc20_address}
                  </p>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

export default Wallet;
