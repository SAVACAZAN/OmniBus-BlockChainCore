import { useEffect, useState } from "react";
import { WebSocketProvider } from "./stores/WebSocketProvider";
import { Header } from "./components/layout/Header";
import { Footer } from "./components/layout/Footer";
import { Dashboard } from "./components/dashboard/Dashboard";
import { BlocksPage } from "./components/blocks/BlocksPage";
import { BlockPage } from "./components/explorer/BlockPage";
import { TxPage } from "./components/explorer/TxPage";
import { AddressPage } from "./components/explorer/AddressPage";
import { MempoolPage } from "./components/mempool/MempoolPage";
import { StatsPage } from "./components/stats/StatsPage";
import { WalletPage } from "./components/wallet/WalletPage";
import { NetworkPage } from "./components/network/NetworkPage";
import { FaucetPage } from "./components/faucet/FaucetPage";
import { RichListPage } from "./components/richlist/RichListPage";
import { AgentsPage } from "./components/agents/AgentsPage";
import { ReputationPage } from "./components/reputation/ReputationPage";
import { StakePage } from "./components/stake/StakePage";
import { DailyAuditPage } from "./components/audit/DailyAuditPage";
import { ValidatorsPage } from "./components/validators/ValidatorsPage";
import { NamesPage } from "./components/names/NamesPage";
import { ExchangePage } from "./components/exchange/ExchangePage";
import { ZeroDayPage } from "./components/zeroday/ZeroDayPage";
import { ApiDocsPage } from "./components/api/ApiDocsPage";
import { BridgePage } from "./components/bridge/BridgePage";
import { AtomicSwapPanel } from "./components/swap/AtomicSwapPanel";
import { MatrixBackground } from "./components/effects/MatrixBackground";
import { PlasmaSlotProvider } from "./components/effects/PlasmaSlotContext";
import { ProfilePage } from "./components/profile/ProfilePage";
import { ProfileInitToast } from "./components/profile/ProfileInitToast";
import { DocsPage } from "./components/docs/DocsPage";
import { VaultPage } from "./components/vault/VaultPage";

export type TabId = "dashboard" | "blocks" | "mempool" | "stats" | "wallet" | "network" | "faucet" | "richlist" | "agents" | "reputation" | "stake" | "audit" | "validators" | "names" | "exchange" | "bridge" | "swap" | "zeroday" | "api" | "profile" | "roadmap" | "docs" | "vault";

const TABS: { id: TabId; label: string }[] = [
  { id: "dashboard", label: "Dashboard" },
  { id: "blocks", label: "Blocks" },
  { id: "mempool", label: "Mempool" },
  { id: "stats", label: "Stats" },
  { id: "richlist", label: "Rich List" },
  { id: "reputation", label: "Reputation" },
  { id: "stake", label: "Stake" },
  { id: "audit", label: "Audit" },
  { id: "validators", label: "Validators" },
  { id: "names", label: ".omnibus" },
  { id: "exchange", label: "Exchange" },
  { id: "bridge", label: "Bridge" },
  { id: "swap", label: "Swap" },
  { id: "agents", label: "Agents" },
  { id: "profile", label: "Profile" },
  { id: "wallet", label: "Wallet" },
  { id: "network", label: "Network" },
  { id: "faucet", label: "Faucet" },
  { id: "zeroday", label: "0day" },
  { id: "api", label: "API" },
  { id: "docs", label: "Docs" },
  { id: "roadmap", label: "Roadmap" },
  { id: "vault", label: "🔐 Vault" },
];

// Bottom nav: 4 primary tabs + "More" drawer
const BOTTOM_NAV_PRIMARY: { id: TabId; label: string; icon: React.ReactNode }[] = [
  {
    id: "dashboard",
    label: "Home",
    icon: (
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
        <rect x="3" y="3" width="7" height="7" rx="1" />
        <rect x="14" y="3" width="7" height="7" rx="1" />
        <rect x="3" y="14" width="7" height="7" rx="1" />
        <rect x="14" y="14" width="7" height="7" rx="1" />
      </svg>
    ),
  },
  {
    id: "blocks",
    label: "Blocks",
    icon: (
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
        <rect x="2" y="7" width="20" height="14" rx="2" />
        <path d="M16 7V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v2" />
      </svg>
    ),
  },
  {
    id: "wallet",
    label: "Wallet",
    icon: (
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
        <path d="M20 12V8H6a2 2 0 0 1-2-2c0-1.1.9-2 2-2h12v4" />
        <path d="M4 6v12c0 1.1.9 2 2 2h14v-4" />
        <path d="M18 12a2 2 0 0 0-2 2c0 1.1.9 2 2 2h4v-4h-4z" />
      </svg>
    ),
  },
  {
    id: "exchange",
    label: "Exchange",
    icon: (
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
        <path d="M7 16V4m0 0L3 8m4-4l4 4" />
        <path d="M17 8v12m0 0l4-4m-4 4l-4-4" />
      </svg>
    ),
  },
];

type ExplorerDeepLink =
  | { kind: "block"; height: number }
  | { kind: "tx"; hash: string }
  | { kind: "address"; addr: string }
  | null;

export default function App() {
  const [activeTab, setActiveTab] = useState<TabId>("dashboard");
  const [showMoreDrawer, setShowMoreDrawer] = useState(false);
  const [profileAddressOverride, setProfileAddressOverride] = useState<string | undefined>(undefined);
  const [explorerDeepLink, setExplorerDeepLink] = useState<ExplorerDeepLink>(null);

  const handleTabSelect = (tab: TabId) => {
    setActiveTab(tab);
    setShowMoreDrawer(false);
    if (tab !== "profile") setProfileAddressOverride(undefined);
    if (tab !== "blocks") setExplorerDeepLink(null);
  };

  const handleExplorerNavigate = (hash: string) => {
    window.location.hash = hash;
  };

  useEffect(() => {
    const parseHash = () => {
      const h = window.location.hash || "";

      // Profile deep link
      const profileM = h.match(/^#\/profile\/([A-Za-z0-9_.]+)/);
      if (profileM) {
        setProfileAddressOverride(profileM[1]);
        setActiveTab("profile");
        setExplorerDeepLink(null);
        return;
      }

      // Block deep link: #/block/12345
      const blockM = h.match(/^#\/block\/(\d+)$/);
      if (blockM) {
        setExplorerDeepLink({ kind: "block", height: parseInt(blockM[1], 10) });
        setActiveTab("blocks");
        return;
      }

      // TX deep link: #/tx/<64-hex>
      const txM = h.match(/^#\/tx\/([0-9a-fA-F]{64})$/);
      if (txM) {
        setExplorerDeepLink({ kind: "tx", hash: txM[1] });
        setActiveTab("blocks");
        return;
      }

      // Address deep link: #/address/<addr>
      const addrM = h.match(/^#\/address\/(.+)$/);
      if (addrM) {
        setExplorerDeepLink({ kind: "address", addr: addrM[1] });
        setActiveTab("blocks");
        return;
      }

      // Blocks list: #/blocks
      if (h === "#/blocks") {
        setExplorerDeepLink(null);
        setActiveTab("blocks");
        return;
      }

      // Direct tab nav: #/<tabId> or legacy #/exchange etc.
      const tabId = h.replace(/^#\/?/, "") as TabId;
      if (tabId && TABS.some((t) => t.id === tabId)) {
        setExplorerDeepLink(null);
        setActiveTab(tabId);
        if (tabId !== "profile") setProfileAddressOverride(undefined);
        return;
      }

      setExplorerDeepLink(null);
    };
    parseHash();
    window.addEventListener("hashchange", parseHash);
    return () => window.removeEventListener("hashchange", parseHash);
  }, []);

  return (
    <WebSocketProvider><PlasmaSlotProvider>
      <MatrixBackground opacity={0.35} />
      <div className="min-h-screen flex flex-col bg-mempool-bg/40 relative" style={{ zIndex: 1 }}>
        <Header />

        {/* ── Desktop Tab Bar (sm+) ── */}
        <nav className="hidden sm:block border-b border-mempool-border bg-mempool-bg-elev backdrop-blur-sm sticky top-[60px] z-40">
          <div className="max-w-7xl mx-auto px-4 flex gap-1 overflow-x-auto scrollbar-none">
            {TABS.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`px-4 py-2.5 text-sm font-medium transition-colors relative flex-shrink-0 ${
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

        {/* ── Main content ── */}
        {/* pb-16 on mobile so content isn't hidden under bottom nav */}
        <main className="flex-1 pb-16 sm:pb-0">
          {activeTab === "dashboard" && <Dashboard />}
          {activeTab === "mempool" && <MempoolPage />}
          {activeTab === "stats" && <StatsPage />}
          {activeTab === "blocks" && (
            explorerDeepLink?.kind === "block"
              ? <BlockPage height={explorerDeepLink.height} onNavigate={handleExplorerNavigate} />
              : explorerDeepLink?.kind === "tx"
              ? <TxPage hash={explorerDeepLink.hash} onNavigate={handleExplorerNavigate} />
              : explorerDeepLink?.kind === "address"
              ? <AddressPage addr={explorerDeepLink.addr} onNavigate={handleExplorerNavigate} />
              : <BlocksPage />
          )}
          {activeTab === "wallet" && <WalletPage />}
          {activeTab === "network" && <NetworkPage />}
          {activeTab === "faucet" && <FaucetPage />}
          {activeTab === "zeroday" && <ZeroDayPage />}
          {activeTab === "richlist" && <RichListPage />}
          {activeTab === "agents" && <AgentsPage />}
          {activeTab === "reputation" && <ReputationPage />}
          {activeTab === "stake" && <StakePage />}
          {activeTab === "audit" && <DailyAuditPage />}
          {activeTab === "validators" && <ValidatorsPage />}
          {activeTab === "names" && <NamesPage />}
          {activeTab === "exchange" && <ExchangePage />}
          {activeTab === "bridge" && <BridgePage />}
          {activeTab === "swap" && <AtomicSwapPanel />}
          {activeTab === "api" && <ApiDocsPage />}
          {activeTab === "docs" && <DocsPage />}
          {activeTab === "profile" && <ProfilePage address={profileAddressOverride} />}
          {activeTab === "vault" && <VaultPage />}
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

        {/* ── Mobile Bottom Navigation (< sm) ── */}
        <nav className="sm:hidden fixed bottom-0 left-0 right-0 z-50 bg-mempool-bg-elev border-t border-mempool-border flex items-stretch">
          {BOTTOM_NAV_PRIMARY.map((item) => (
            <button
              key={item.id}
              onClick={() => handleTabSelect(item.id)}
              className={`flex-1 flex flex-col items-center justify-center gap-0.5 py-2 px-1 text-[10px] font-medium transition-colors ${
                activeTab === item.id && !showMoreDrawer
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim"
              }`}
            >
              {item.icon}
              <span>{item.label}</span>
            </button>
          ))}

          {/* "More" button */}
          <button
            onClick={() => setShowMoreDrawer((v) => !v)}
            className={`flex-1 flex flex-col items-center justify-center gap-0.5 py-2 px-1 text-[10px] font-medium transition-colors ${
              showMoreDrawer ? "text-mempool-blue" : "text-mempool-text-dim"
            }`}
          >
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="5" r="1" fill="currentColor" />
              <circle cx="12" cy="12" r="1" fill="currentColor" />
              <circle cx="12" cy="19" r="1" fill="currentColor" />
            </svg>
            <span>More</span>
          </button>
        </nav>

        {/* ── More Drawer (mobile) ── */}
        {showMoreDrawer && (
          <>
            {/* Backdrop */}
            <div
              className="sm:hidden fixed inset-0 z-40 bg-black/60"
              onClick={() => setShowMoreDrawer(false)}
            />
            {/* Sheet */}
            <div className="sm:hidden fixed bottom-16 left-0 right-0 z-50 bg-mempool-bg-elev border-t border-mempool-border rounded-t-2xl max-h-[60vh] overflow-y-auto">
              <div className="p-1 pt-3">
                <div className="w-10 h-1 bg-mempool-border rounded-full mx-auto mb-4" />
                <div className="grid grid-cols-3 gap-0.5">
                  {TABS.filter(
                    (t) => !BOTTOM_NAV_PRIMARY.some((p) => p.id === t.id)
                  ).map((tab) => (
                    <button
                      key={tab.id}
                      onClick={() => handleTabSelect(tab.id)}
                      className={`flex flex-col items-center justify-center gap-1 py-4 rounded-xl text-xs font-medium transition-colors ${
                        activeTab === tab.id
                          ? "bg-mempool-blue/10 text-mempool-blue"
                          : "text-mempool-text-dim hover:text-mempool-text hover:bg-mempool-bg-light"
                      }`}
                    >
                      <span className="text-base">
                        {tab.id === "mempool" ? "⏳" :
                         tab.id === "stats" ? "📊" :
                         tab.id === "richlist" ? "🏆" :
                         tab.id === "reputation" ? "⭐" :
                         tab.id === "audit" ? "📋" :
                         tab.id === "names" ? "🔖" :
                         tab.id === "bridge" ? "🌉" :
                         tab.id === "swap" ? "🔄" :
                         tab.id === "agents" ? "🤖" :
                         tab.id === "network" ? "🌐" :
                         tab.id === "faucet" ? "💧" :
                         tab.id === "zeroday" ? "🛡️" :
                         tab.id === "api" ? "📡" :
                         tab.id === "profile" ? "🪪" :
                         tab.id === "docs" ? "📚" :
                         tab.id === "roadmap" ? "🗺️" :
                         tab.id === "vault" ? "🔐" : "•"}
                      </span>
                      {tab.label}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </>
        )}

        <ProfileInitToast
          onOpenProfile={(addr) => {
            setProfileAddressOverride(addr);
            setActiveTab("profile");
          }}
        />
      </div>
    </PlasmaSlotProvider></WebSocketProvider>
  );
}
