import { useState } from "react";
import { WebSocketProvider } from "./stores/WebSocketProvider";
import { Header } from "./components/layout/Header";
import { Footer } from "./components/layout/Footer";
import { Dashboard } from "./components/dashboard/Dashboard";
import { BlocksPage } from "./components/blocks/BlocksPage";
import { WalletPage } from "./components/wallet/WalletPage";
import { NetworkPage } from "./components/network/NetworkPage";
import { FaucetPage } from "./components/faucet/FaucetPage";
import { RichListPage } from "./components/richlist/RichListPage";
import { AgentsPage } from "./components/agents/AgentsPage";
import { ReputationPage } from "./components/reputation/ReputationPage";
import { NamesPage } from "./components/names/NamesPage";
import { ExchangePage } from "./components/exchange/ExchangePage";
import { ZeroDayPage } from "./components/zeroday/ZeroDayPage";
import { ApiDocsPage } from "./components/api/ApiDocsPage";
import { BridgePage } from "./components/bridge/BridgePage";
import { AtomicSwapPanel } from "./components/swap/AtomicSwapPanel";
import { MatrixBackground } from "./components/effects/MatrixBackground";
import { PlasmaSlotProvider } from "./components/effects/PlasmaSlotContext";

export type TabId = "dashboard" | "blocks" | "wallet" | "network" | "faucet" | "richlist" | "agents" | "reputation" | "names" | "exchange" | "bridge" | "swap" | "zeroday" | "api" | "roadmap";

const TABS: { id: TabId; label: string }[] = [
  { id: "dashboard", label: "Dashboard" },
  { id: "blocks", label: "Blocks" },
  { id: "richlist", label: "Rich List" },
  { id: "reputation", label: "Reputation" },
  { id: "names", label: ".omnibus" },
  { id: "exchange", label: "Exchange" },
  { id: "bridge", label: "Bridge" },
  { id: "swap", label: "Swap" },
  { id: "agents", label: "Agents" },
  { id: "wallet", label: "Wallet" },
  { id: "network", label: "Network" },
  { id: "faucet", label: "Faucet" },
  { id: "zeroday", label: "0day" },
  { id: "api", label: "API" },
  { id: "roadmap", label: "Roadmap" },
];

export default function App() {
  const [activeTab, setActiveTab] = useState<TabId>("dashboard");

  return (
    <WebSocketProvider><PlasmaSlotProvider>
      <MatrixBackground opacity={0.35} />
      <div className="min-h-screen flex flex-col bg-mempool-bg/40 relative" style={{ zIndex: 1 }}>
        <Header />

        {/* Tab Bar */}
        <nav className="border-b border-mempool-border bg-mempool-bg-elev backdrop-blur-sm sticky top-[60px] z-40">
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
          {activeTab === "faucet" && <FaucetPage />}
          {activeTab === "zeroday" && <ZeroDayPage />}
          {activeTab === "richlist" && <RichListPage />}
          {activeTab === "agents" && <AgentsPage />}
          {activeTab === "reputation" && <ReputationPage />}
          {activeTab === "names" && <NamesPage />}
          {activeTab === "exchange" && <ExchangePage />}
          {activeTab === "bridge" && <BridgePage />}
          {activeTab === "swap" && <AtomicSwapPanel />}
          {activeTab === "api" && <ApiDocsPage />}
          {activeTab === "roadmap" && (
            <iframe
              src="/roadmap-flow.html"
              title="Roadmap — Pyramid &amp; Hourglass"
              className="w-full"
              style={{ height: "calc(100vh - 140px)", border: "none" }}
            />
          )}
        </main>
        <Footer />
      </div>
    </PlasmaSlotProvider></WebSocketProvider>
  );
}
