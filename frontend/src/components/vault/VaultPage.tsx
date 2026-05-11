/**
 * VaultPage.tsx — Security-focused tab container for advanced wallet features.
 *
 * Sub-tabs:
 *   Cold Wallet  — watch-only address monitoring
 *   Timelock     — CLTV vaults (time-delayed spend)
 *   Covenant     — destination whitelist enforcement
 *   Treasury     — auto-distribute protocol fees / payouts
 *   Multisig     — M-of-N multi-signature wallets
 */

import { useState } from "react";
import { ShieldCheck } from "lucide-react";
import { ColdWalletPanel } from "./ColdWalletPanel";
import { TimelockPanel } from "./TimelockPanel";
import { CovenantPanel } from "./CovenantPanel";
import { TreasuryPanel } from "./TreasuryPanel";
import { MultisigPanel } from "./MultisigPanel";

type VaultSubTab = "coldwallet" | "timelock" | "covenant" | "treasury" | "multisig";

const SUB_TABS: { id: VaultSubTab; label: string; icon: string }[] = [
  { id: "coldwallet", label: "Cold Wallet", icon: "👁️" },
  { id: "timelock",   label: "Timelock",    icon: "⏱️" },
  { id: "covenant",   label: "Covenant",    icon: "📜" },
  { id: "treasury",   label: "Treasury",    icon: "🏛️" },
  { id: "multisig",   label: "Multisig",    icon: "🔑" },
];

export function VaultPage() {
  const [activeTab, setActiveTab] = useState<VaultSubTab>("coldwallet");

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-3 sm:p-4 border border-mempool-border backdrop-blur-sm">
      {/* Header */}
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <ShieldCheck className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Vault
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-[10px] text-mempool-text-dim hidden sm:block">
          Advanced security features
        </span>
      </div>

      {/* Sub-tab bar */}
      <div className="flex gap-0.5 border-b border-mempool-border mb-5 overflow-x-auto scrollbar-none">
        {SUB_TABS.map((t) => {
          const active = activeTab === t.id;
          return (
            <button
              key={t.id}
              onClick={() => setActiveTab(t.id)}
              className={
                "relative flex-shrink-0 flex items-center gap-1.5 px-3 sm:px-4 py-2.5 text-xs font-medium uppercase tracking-wider transition-colors whitespace-nowrap " +
                (active
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text")
              }
            >
              <span className="text-sm leading-none">{t.icon}</span>
              <span className="hidden sm:inline">{t.label}</span>
              <span className="sm:hidden">{t.label.split(" ")[0]}</span>
              {active && (
                <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-mempool-blue" />
              )}
            </button>
          );
        })}
      </div>

      {/* Panel content */}
      {activeTab === "coldwallet" && <ColdWalletPanel />}
      {activeTab === "timelock"   && <TimelockPanel />}
      {activeTab === "covenant"   && <CovenantPanel />}
      {activeTab === "treasury"   && <TreasuryPanel />}
      {activeTab === "multisig"   && <MultisigPanel />}
    </section>
  );
}
