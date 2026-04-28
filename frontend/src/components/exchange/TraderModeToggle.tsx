import { useEffect, useState } from "react";

export type TraderMode = "real" | "paper";

const STORAGE_KEY = "omnibus.exchange.trader_mode";

export function getTraderMode(): TraderMode {
  if (typeof localStorage === "undefined") return "paper";
  const v = localStorage.getItem(STORAGE_KEY);
  return v === "real" ? "real" : "paper";
}

export function setTraderMode(m: TraderMode) {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(STORAGE_KEY, m);
  // Also broadcast a custom event so other components can react in-page.
  window.dispatchEvent(new CustomEvent("omnibus:trader-mode", { detail: m }));
}

export function useTraderMode(): [TraderMode, (m: TraderMode) => void] {
  const [mode, setMode] = useState<TraderMode>(getTraderMode);
  useEffect(() => {
    const onChange = (e: Event) => {
      const ce = e as CustomEvent<TraderMode>;
      if (ce.detail) setMode(ce.detail);
    };
    window.addEventListener("omnibus:trader-mode", onChange);
    return () => window.removeEventListener("omnibus:trader-mode", onChange);
  }, []);
  const set = (m: TraderMode) => {
    setTraderMode(m);
    setMode(m);
  };
  return [mode, set];
}

/**
 * Big in-your-face Real ↔ Paper toggle. Lives at the top of the Trade
 * tab so the user always sees which mode they're in. Default = paper
 * (so first-time users can't blow real OMNI by accident).
 */
export function TraderModeToggle() {
  const [mode, setMode] = useTraderMode();
  return (
    <div
      className={`rounded-lg border-2 p-3 flex items-center justify-between gap-3 ${
        mode === "real"
          ? "border-mempool-green/60 bg-mempool-green/10"
          : "border-yellow-500/60 bg-yellow-500/10"
      }`}
    >
      <div>
        <div
          className={`text-xs uppercase tracking-wider font-semibold ${
            mode === "real" ? "text-mempool-green" : "text-yellow-300"
          }`}
        >
          {mode === "real" ? "💰 REAL TRADER" : "🎮 PAPER TRADER (Demo)"}
        </div>
        <div className="text-[11px] text-mempool-text-dim mt-0.5">
          {mode === "real"
            ? "Orders settle in real OMNI. Profit/loss is real."
            : "Orders settle in OMNI_DEMO. Practice mode — no real funds at risk."}
        </div>
      </div>
      <div className="flex gap-1 bg-mempool-bg/60 rounded p-0.5">
        <button
          onClick={() => setMode("paper")}
          className={`px-3 py-1.5 text-xs rounded transition-colors ${
            mode === "paper"
              ? "bg-yellow-500 text-black font-semibold"
              : "text-mempool-text-dim hover:text-mempool-text"
          }`}
        >
          🎮 Paper
        </button>
        <button
          onClick={() => setMode("real")}
          className={`px-3 py-1.5 text-xs rounded transition-colors ${
            mode === "real"
              ? "bg-mempool-green text-black font-semibold"
              : "text-mempool-text-dim hover:text-mempool-text"
          }`}
        >
          💰 Real
        </button>
      </div>
    </div>
  );
}
