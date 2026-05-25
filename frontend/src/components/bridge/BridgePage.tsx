/**
 * BridgePage.tsx — "Buy OMNI" landing.
 *
 * Replaces the old OMNI-out bridge UI (lock-and-mint to Base/Liberty) which
 * no longer fits the architecture. OmniBus chain holds OMNI only — no
 * IOU-tokens for foreign assets, no wOMNI on other chains. Everything
 * cross-chain runs through atomic swap (HTLC) via OmniBus Wallet, which
 * receives the user's USDC/ETH/SOL/etc. on the user's own chain.
 *
 * This page is purely educational + a chain registry showcase. The actual
 * buy flow lives in the Exchange tab. Decision recorded in
 * memory/project_omnibus_bridge_in_only_model.md (2026-05-14).
 *
 * Legacy code preserved at BridgePage.legacy-omni-out.tsx.bak for history.
 */

import { CHAINS, chainCounts, type ChainFamily } from "../../api/chains";

const FAMILY_ORDER: ChainFamily[] = [
  "OmniBus",
  "EVM",
  "Bitcoin",
  "Solana",
  "Cardano",
  "Polkadot",
  "Cosmos",
  "NEAR",
  "XRP",
  "Stellar",
  "Algorand",
  "Zilliqa",
  "MultiversX",
];

const FAMILY_LABELS: Record<ChainFamily, string> = {
  OmniBus:    "OmniBus native",
  EVM:        "EVM (Ethereum & L2s)",
  Bitcoin:    "Bitcoin family",
  Solana:     "Solana",
  Cardano:    "Cardano",
  Polkadot:   "Polkadot",
  Cosmos:     "Cosmos",
  NEAR:       "NEAR",
  XRP:        "XRP Ledger",
  Stellar:    "Stellar",
  Algorand:   "Algorand",
  Zilliqa:    "Zilliqa",
  MultiversX: "MultiversX",
};

export function BridgePage() {
  const counts = chainCounts();

  return (
    <div className="max-w-5xl mx-auto px-3 sm:px-4 py-6 sm:py-8 space-y-6">
      {/* Hero */}
      <header className="space-y-2">
        <h1 className="text-2xl sm:text-3xl font-bold text-mempool-text">Buy OMNI</h1>
        <p className="text-sm text-mempool-text-dim max-w-3xl leading-relaxed">
          OmniBus chain holds <span className="text-mempool-green font-semibold">OMNI only</span>.
          To get OMNI, send any supported asset from your chain — USDC, ETH, MATIC,
          SOL, ATOM and others — and OmniBus Wallet settles an atomic swap.
          You receive native OMNI on the OmniBus chain. Your funds stay on
          your chain until the swap fills.
        </p>
      </header>

      {/* How it works */}
      <section className="grid grid-cols-1 sm:grid-cols-3 gap-3 sm:gap-4">
        <Step
          n={1}
          title="Place order"
          body="Open the Exchange tab and choose 'OMNI / <your asset>'. Pick the chain where you hold the asset (Sepolia, Base, Polygon, Solana, etc.). Set price and amount."
        />
        <Step
          n={2}
          title="Atomic HTLC"
          body="OmniBus Wallet generates a hash-lock and an OMNI escrow on OmniBus. You sign a payment on your chain to a corresponding HTLC. Both sides are time-locked."
        />
        <Step
          n={3}
          title="Settle"
          body="The chain reveals the preimage when both locks are funded. You receive OMNI on OmniBus; OmniBus Wallet receives your asset on your chain. No custody."
        />
      </section>

      {/* CTA */}
      <div className="rounded-xl border border-mempool-green/40 bg-mempool-green/5 p-4 sm:p-5 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-mempool-green uppercase tracking-wider">Ready to buy OMNI?</h2>
          <p className="text-xs text-mempool-text-dim mt-1">
            All cross-chain trades run through the Exchange. Open an order there;
            this page is just the reference of which chains we can settle with.
          </p>
        </div>
        <button
          onClick={() => { window.location.hash = "#exchange"; }}
          className="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-mempool-green text-mempool-bg font-semibold hover:bg-mempool-green/90 transition-colors whitespace-nowrap"
        >
          Open Exchange →
        </button>
      </div>

      {/* Chain registry */}
      <section className="space-y-3">
        <div className="flex items-baseline justify-between flex-wrap gap-2">
          <h2 className="text-lg font-semibold text-mempool-text">Supported chains</h2>
          <p className="text-xs text-mempool-text-dim">
            <span className="text-mempool-green font-semibold">{counts.enabled} live</span>
            {" · "}
            <span className="text-mempool-text-dim">{counts.disabled} coming soon</span>
            {" · "}
            <span className="text-mempool-text-dim">{counts.total} total · {counts.testnets} testnets</span>
          </p>
        </div>

        {FAMILY_ORDER.map((family) => {
          const rows = CHAINS.filter((c) => c.family === family);
          if (rows.length === 0) return null;
          return (
            <div key={family} className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-hidden">
              <header className="px-4 py-2 border-b border-mempool-border bg-mempool-bg/30">
                <h3 className="text-xs font-semibold text-mempool-text uppercase tracking-wider">
                  {FAMILY_LABELS[family]}
                  <span className="ml-2 text-mempool-text-dim font-normal normal-case">({rows.length})</span>
                </h3>
              </header>
              <ul className="divide-y divide-mempool-border/40">
                {rows.map((c) => (
                  <li
                    key={c.id}
                    className={`flex items-center justify-between gap-3 px-4 py-2.5 ${c.enabled ? "" : "opacity-50"}`}
                  >
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className={`text-sm font-medium ${c.color}`}>{c.label}</span>
                        {c.testnet && (
                          <span className="text-[9px] uppercase tracking-wider bg-mempool-orange/20 text-mempool-orange px-1.5 py-0.5 rounded">
                            testnet
                          </span>
                        )}
                        {c.enabled ? (
                          <span className="text-[9px] uppercase tracking-wider bg-mempool-green/20 text-mempool-green px-1.5 py-0.5 rounded">
                            live
                          </span>
                        ) : (
                          <span className="text-[9px] uppercase tracking-wider bg-mempool-text-dim/20 text-mempool-text-dim px-1.5 py-0.5 rounded">
                            soon
                          </span>
                        )}
                      </div>
                      <div className="flex items-center gap-3 text-[10px] text-mempool-text-dim mt-0.5 font-mono">
                        <span>symbol: <span className="text-mempool-text">{c.symbol}</span></span>
                        {c.chainId > 0 && <span>chainId: <span className="text-mempool-text">{c.chainId}</span></span>}
                        <span>coin_type: <span className="text-mempool-text">{c.coinType}</span></span>
                      </div>
                    </div>
                    {c.explorerTx && (
                      <a
                        href={c.explorerTx.replace(/\/tx\/$|\/transactions\/$|\/extrinsic\/$|\/txns\/$/, "")}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-[10px] text-mempool-blue hover:underline shrink-0"
                      >
                        explorer ↗
                      </a>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          );
        })}
      </section>

      {/* Note */}
      <p className="text-[11px] text-mempool-text-dim/70 italic leading-relaxed">
        Note: there is no &quot;wOMNI&quot; on Ethereum, Base, or any other chain — OMNI
        only exists on the OmniBus chain. There is no &quot;deposit USDC to
        OmniBus&quot; — your USDC stays on its native chain at OmniBus Wallet&apos;s
        address. Everything settles atomically through HTLC so neither side can
        run away with the funds.
      </p>
    </div>
  );
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function Step({ n, title, body }: { n: number; title: string; body: string }) {
  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 sm:p-5 space-y-2">
      <div className="flex items-center gap-2">
        <span className="w-7 h-7 rounded-full bg-mempool-blue/20 text-mempool-blue flex items-center justify-center font-bold">
          {n}
        </span>
        <h3 className="text-sm font-semibold text-mempool-text">{title}</h3>
      </div>
      <p className="text-xs text-mempool-text-dim leading-relaxed">{body}</p>
    </div>
  );
}
