import { useState } from "react";
import { WebSocketProvider } from "./stores/WebSocketProvider";
import { Header } from "./components/layout/Header";
import { Footer } from "./components/layout/Footer";
import { Dashboard } from "./components/dashboard/Dashboard";
import { BlocksPage } from "./components/blocks/BlocksPage";
import { WalletPage } from "./components/wallet/WalletPage";
import { NetworkPage } from "./components/network/NetworkPage";

export type TabId = "dashboard" | "blocks" | "wallet" | "network";

const TABS: { id: TabId; label: string }[] = [
  { id: "dashboard", label: "Dashboard" },
  { id: "blocks", label: "Blocks" },
  { id: "wallet", label: "Wallet" },
  { id: "network", label: "Network" },
];

export default function App() {
  const [activeTab, setActiveTab] = useState<TabId>("dashboard");

  return (
    <WebSocketProvider>
      <div className="min-h-screen flex flex-col bg-mempool-bg">
        <Header />

        {/* Tab Bar */}
        <nav className="border-b border-mempool-border bg-mempool-bg/80 backdrop-blur-sm sticky top-[60px] z-40">
          <div className="max-w-7xl mx-auto px-4 flex gap-1">
            {TABS.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`px-4 py-2.5 text-sm font-medium transition-colors relative ${
                  activeTab === tab.id
                    ? "text-mempool-blue"
                    : "text-mempool-text-dim hover:text-mempool-text"
                }`}
              >
                {tab.label}
                {activeTab === tab.id && (
                  <div className="absolute bottom-0 left-0 right-0 h-0.5 bg-mempool-blue rounded-full" />
                )}
              </button>
            ))}
          </div>
        </nav>

        <main className="flex-1">
          {activeTab === "dashboard" && <Dashboard />}
          {activeTab === "blocks" && <BlocksPage />}
          {activeTab === "wallet" && <WalletPage />}
          {activeTab === "network" && <NetworkPage />}
        </main>
        <Footer />
      </div>
    </WebSocketProvider>
  );
}
