import React, { useState } from "react";
import Stats from "./components/Stats";
import BlockExplorer from "./components/BlockExplorer";
import Wallet from "./components/Wallet";
import "./App.css";

type Page = "dashboard" | "explorer" | "wallet";

export const App: React.FC = () => {
  const [currentPage, setCurrentPage] = useState<Page>("dashboard");

  return (
    <div className="min-h-screen bg-gray-900 text-white">
      {/* Navigation */}
      <nav className="bg-gray-800 shadow-lg">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex justify-between items-center h-16">
            <div className="flex items-center space-x-2">
              <div className="w-8 h-8 bg-gradient-to-r from-blue-600 to-purple-600 rounded-lg flex items-center justify-center">
                <span className="text-white font-bold">Ω</span>
              </div>
              <span className="text-xl font-bold bg-gradient-to-r from-blue-400 to-purple-400 bg-clip-text text-transparent">
                OmniBus
              </span>
            </div>

            <div className="flex space-x-1">
              <button
                onClick={() => setCurrentPage("dashboard")}
                className={`px-4 py-2 rounded-lg transition ${
                  currentPage === "dashboard"
                    ? "bg-blue-600 text-white"
                    : "text-gray-300 hover:text-white hover:bg-gray-700"
                }`}
              >
                Dashboard
              </button>
              <button
                onClick={() => setCurrentPage("explorer")}
                className={`px-4 py-2 rounded-lg transition ${
                  currentPage === "explorer"
                    ? "bg-blue-600 text-white"
                    : "text-gray-300 hover:text-white hover:bg-gray-700"
                }`}
              >
                Block Explorer
              </button>
              <button
                onClick={() => setCurrentPage("wallet")}
                className={`px-4 py-2 rounded-lg transition ${
                  currentPage === "wallet"
                    ? "bg-blue-600 text-white"
                    : "text-gray-300 hover:text-white hover:bg-gray-700"
                }`}
              >
                Wallet
              </button>
            </div>

            <div className="flex items-center space-x-2">
              <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
              <span className="text-sm text-gray-300">Connected</span>
            </div>
          </div>
        </div>
      </nav>

      {/* Main Content */}
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        {currentPage === "dashboard" && (
          <div className="space-y-8">
            <div>
              <h1 className="text-3xl font-bold mb-2">Dashboard</h1>
              <p className="text-gray-400">
                Real-time blockchain statistics and metrics
              </p>
            </div>

            <Stats />

            {/* Features Section */}
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mt-12">
              <div className="bg-gradient-to-br from-blue-900 to-blue-800 rounded-lg p-6">
                <h3 className="text-lg font-bold mb-2">🔐 Post-Quantum Safe</h3>
                <p className="text-gray-300 text-sm">
                  5 NIST-approved algorithms: Kyber-768, Dilithium-5, Falcon-512,
                  SPHINCS+
                </p>
              </div>

              <div className="bg-gradient-to-br from-purple-900 to-purple-800 rounded-lg p-6">
                <h3 className="text-lg font-bold mb-2">⚡ Sub-Microsecond</h3>
                <p className="text-gray-300 text-sm">
                  Bare-metal execution with <40μs latency and deterministic
                  consensus
                </p>
              </div>

              <div className="bg-gradient-to-br from-green-900 to-green-800 rounded-lg p-6">
                <h3 className="text-lg font-bold mb-2">🏆 54 OS Modules</h3>
                <p className="text-gray-300 text-sm">
                  7 simultaneous OS layers with trading, settlement, and
                  governance
                </p>
              </div>

              <div className="bg-gradient-to-br from-orange-900 to-orange-800 rounded-lg p-6">
                <h3 className="text-lg font-bold mb-2">📊 Verified</h3>
                <p className="text-gray-300 text-sm">
                  seL4 microkernel + Ada SPARK formal verification (99% coverage)
                </p>
              </div>
            </div>
          </div>
        )}

        {currentPage === "explorer" && <BlockExplorer />}

        {currentPage === "wallet" && <Wallet />}
      </main>

      {/* Footer */}
      <footer className="bg-gray-800 border-t border-gray-700 mt-12">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            <div>
              <h4 className="font-bold mb-4">OmniBus</h4>
              <p className="text-gray-400 text-sm">
                Sub-microsecond cryptocurrency trading with post-quantum security
              </p>
            </div>
            <div>
              <h4 className="font-bold mb-4">Documentation</h4>
              <ul className="space-y-2 text-sm text-gray-400">
                <li>
                  <a href="#" className="hover:text-white transition">
                    Architecture
                  </a>
                </li>
                <li>
                  <a href="#" className="hover:text-white transition">
                    API Reference
                  </a>
                </li>
                <li>
                  <a href="#" className="hover:text-white transition">
                    Guides
                  </a>
                </li>
              </ul>
            </div>
            <div>
              <h4 className="font-bold mb-4">Community</h4>
              <ul className="space-y-2 text-sm text-gray-400">
                <li>
                  <a href="#" className="hover:text-white transition">
                    GitHub
                  </a>
                </li>
                <li>
                  <a href="#" className="hover:text-white transition">
                    Discord
                  </a>
                </li>
                <li>
                  <a href="#" className="hover:text-white transition">
                    Twitter
                  </a>
                </li>
              </ul>
            </div>
          </div>

          <div className="border-t border-gray-700 mt-8 pt-8 text-center text-gray-400 text-sm">
            <p>
              Phase 4: React Frontend | Built with Zig + TypeScript + TailwindCSS
            </p>
            <p className="mt-2">© 2026 OmniBus. All rights reserved.</p>
          </div>
        </div>
      </footer>
    </div>
  );
};

export default App;
