import React, { useState } from "react";
import Stats from "./components/Stats";
import BlockExplorer from "./components/BlockExplorer";
import Wallet from "./components/Wallet";
import "./App.css";

type Page = "dashboard" | "explorer" | "wallet";

export const App: React.FC = () => {
  const [currentPage, setCurrentPage] = useState<Page>("dashboard");

  const getPageIcon = (page: Page): string => {
    const icons = {
      dashboard: "📊",
      explorer: "🔍",
      wallet: "💰",
    };
    return icons[page];
  };

  const getPageTitle = (page: Page): string => {
    const titles = {
      dashboard: "Dashboard",
      explorer: "Block Explorer",
      wallet: "Wallet",
    };
    return titles[page];
  };

  const getPageDescription = (page: Page): string => {
    const descriptions = {
      dashboard: "Real-time blockchain statistics and block information",
      explorer: "Browse all blocks and transactions on the blockchain",
      wallet: "Manage your OmniBus wallet and balance",
    };
    return descriptions[page];
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-slate-900 via-slate-800 to-slate-900">
      {/* Header */}
      <header className="sticky top-0 z-50 bg-slate-900/80 backdrop-blur-md border-b border-slate-700">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div className="flex justify-between items-center">
            {/* Logo */}
            <div className="flex items-center space-x-3">
              <div className="w-10 h-10 bg-gradient-to-br from-blue-500 to-purple-600 rounded-lg flex items-center justify-center shadow-lg">
                <span className="text-white font-bold text-lg">◆</span>
              </div>
              <div>
                <h1 className="text-xl font-bold bg-gradient-to-r from-blue-400 via-purple-400 to-pink-400 bg-clip-text text-transparent">
                  OmniBus
                </h1>
                <p className="text-xs text-gray-400">Blockchain Explorer</p>
              </div>
            </div>

            {/* Status */}
            <div className="flex items-center space-x-3 px-4 py-2 bg-slate-800 rounded-lg border border-slate-700">
              <div className="flex items-center space-x-2">
                <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
                <span className="text-sm text-gray-300 font-medium">Online</span>
              </div>
              <div className="w-px h-4 bg-slate-600"></div>
              <span className="text-xs text-gray-400">Port 8890</span>
            </div>
          </div>
        </div>
      </header>

      {/* Navigation Tabs */}
      <nav className="bg-slate-800/50 border-b border-slate-700 sticky top-16 z-40">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex space-x-1">
            {(["dashboard", "explorer", "wallet"] as const).map((page) => (
              <button
                key={page}
                onClick={() => setCurrentPage(page)}
                className={`px-6 py-4 font-medium text-sm transition-all border-b-2 ${
                  currentPage === page
                    ? "border-blue-500 text-blue-400 bg-slate-700/50"
                    : "border-transparent text-gray-400 hover:text-gray-300 hover:bg-slate-700/25"
                }`}
              >
                <span className="mr-2">{getPageIcon(page)}</span>
                {page === "dashboard"
                  ? "Dashboard"
                  : page === "explorer"
                    ? "Block Explorer"
                    : "Wallet"}
              </button>
            ))}
          </div>
        </div>
      </nav>

      {/* Main Content */}
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        {/* Page Header */}
        <div className="mb-8 animate-fadeIn">
          <div className="flex items-center space-x-3">
            <span className="text-4xl">{getPageIcon(currentPage)}</span>
            <div>
              <h2 className="text-3xl font-bold text-white">
                {getPageTitle(currentPage)}
              </h2>
              <p className="text-gray-400 text-sm mt-1">
                {getPageDescription(currentPage)}
              </p>
            </div>
          </div>
          <div className="mt-4 h-1 w-20 bg-gradient-to-r from-blue-500 to-purple-600 rounded-full"></div>
        </div>

        {/* Page Content */}
        <div className="animate-slideUp">
          {currentPage === "dashboard" && <Stats />}
          {currentPage === "explorer" && <BlockExplorer />}
          {currentPage === "wallet" && <Wallet />}
        </div>
      </main>

      {/* Footer */}
      <footer className="border-t border-slate-700 bg-slate-900/50 mt-16">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            <div>
              <h4 className="font-semibold text-white mb-3">OmniBus</h4>
              <p className="text-gray-400 text-sm">
                Sub-microsecond blockchain with post-quantum cryptography
              </p>
            </div>
            <div>
              <h4 className="font-semibold text-white mb-3">Network</h4>
              <ul className="space-y-2 text-sm text-gray-400">
                <li>• 10 Active Miners</li>
                <li>• 10,000 H/s Total Hashrate</li>
                <li>• 21M OMNI Total Supply</li>
              </ul>
            </div>
            <div>
              <h4 className="font-semibold text-white mb-3">Features</h4>
              <ul className="space-y-2 text-sm text-gray-400">
                <li>• Post-Quantum Safe</li>
                <li>• Real-time Updates</li>
                <li>• Full Block Data</li>
              </ul>
            </div>
          </div>
          <div className="border-t border-slate-700 mt-8 pt-8 text-center text-gray-500 text-sm">
            <p>© 2026 OmniBus Blockchain • Phase 8 Genesis</p>
          </div>
        </div>
      </footer>
    </div>
  );
};

export default App;
