import { useEffect, useMemo, useState } from "react";
import { rpc, GridConfig, GridStatus } from "../../api/rpc-client";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewTradeEvent } from "../../types";
import { SAT_PER_OMNI, MICRO_PER_USD } from "../../utils/fmt";


type Pair = { id: number; base: string; quote: string; label: string };

function fmtPrice(p: number, quote: string) {
  const v = p / MICRO_PER_USD;
  return quote === "USDC" ? `$${v.toFixed(4)}` : `${v.toFixed(6)} ${quote}`;
}

function fmtBase(a: number, base: string) {
  return `${(a / SAT_PER_OMNI).toFixed(4)} ${base}`;
}

function CreateGridModal({
  pairs,
  owner,
  onClose,
  onCreated,
}: {
  pairs: Pair[];
  owner: string;
  onClose: () => void;
  onCreated: () => void;
}) {
  const [pairId, setPairId] = useState(0);
  const [priceLow, setPriceLow] = useState("");
  const [priceHigh, setPriceHigh] = useState("");
  const [levels, setLevels] = useState("10");
  const [totalBase, setTotalBase] = useState("");
  const [totalQuote, setTotalQuote] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const pair = pairs.find((p) => p.id === pairId) ?? pairs[0];

  async function submit() {
    setError("");
    const pl = parseFloat(priceLow);
    const ph = parseFloat(priceHigh);
    const lv = parseInt(levels, 10);
    const tb = parseFloat(totalBase);
    const tq = parseFloat(totalQuote);
    if (!pl || !ph || !lv || !tb || !tq) { setError("Fill all fields"); return; }
    if (ph <= pl) { setError("price_high must be > price_low"); return; }
    if (lv < 1 || lv > 100) { setError("Levels: 1–100"); return; }
    setLoading(true);
    try {
      await rpc.gridCreate({
        pair_id: pairId,
        price_low: Math.round(pl * MICRO_PER_USD),
        price_high: Math.round(ph * MICRO_PER_USD),
        levels: lv,
        total_base: Math.round(tb * SAT_PER_OMNI),
        total_quote: Math.round(tq * MICRO_PER_USD),
        owner,
      });
      onCreated();
      onClose();
    } catch (e: any) {
      setError(e?.message ?? "Error");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4 overflow-y-auto">
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl w-full max-w-md p-4 sm:p-6 space-y-4 my-4">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-bold text-mempool-text uppercase tracking-wider">Create Grid</h2>
          <button onClick={onClose} className="text-mempool-text-dim hover:text-mempool-text text-lg leading-none">×</button>
        </div>

        <div className="space-y-3">
          <div>
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Pair</label>
            <div className="flex flex-wrap gap-1 mt-1">
              {pairs.map((p) => (
                <button
                  key={p.id}
                  onClick={() => setPairId(p.id)}
                  className={`px-2 py-1 text-xs rounded ${p.id === pairId ? "bg-mempool-blue text-white" : "bg-mempool-bg text-mempool-text-dim hover:text-mempool-text"}`}
                >
                  {p.label}
                </button>
              ))}
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
                Price Low ({pair?.quote ?? "USDC"})
              </label>
              <input
                value={priceLow}
                onChange={(e) => setPriceLow(e.target.value)}
                placeholder="0.10"
                className="w-full mt-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
                Price High ({pair?.quote ?? "USDC"})
              </label>
              <input
                value={priceHigh}
                onChange={(e) => setPriceHigh(e.target.value)}
                placeholder="0.20"
                className="w-full mt-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
              />
            </div>
          </div>

          <div>
            <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Levels per side (1–100)</label>
            <input
              value={levels}
              onChange={(e) => setLevels(e.target.value)}
              placeholder="10"
              className="w-full mt-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
                Total {pair?.base ?? "OMNI"}
              </label>
              <input
                value={totalBase}
                onChange={(e) => setTotalBase(e.target.value)}
                placeholder="500"
                className="w-full mt-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
              />
            </div>
            <div>
              <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
                Total {pair?.quote ?? "USDC"}
              </label>
              <input
                value={totalQuote}
                onChange={(e) => setTotalQuote(e.target.value)}
                placeholder="500"
                className="w-full mt-1 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
              />
            </div>
          </div>

          <p className="text-[10px] text-mempool-text-dim bg-mempool-bg rounded p-2">
            Grid generates {levels || "N"} buy + {levels || "N"} sell orders automatically.
            HTLC is created only at fill time — funds stay in your wallet until then.
          </p>

          {error && <p className="text-orange-400 text-xs">{error}</p>}
        </div>

        <button
          onClick={submit}
          disabled={loading || !owner}
          className="w-full py-2 bg-mempool-blue hover:bg-blue-600 text-white text-xs font-semibold rounded transition-colors disabled:opacity-50"
        >
          {loading ? "Creating…" : owner ? "Create Grid" : "Connect wallet first"}
        </button>
      </div>
    </div>
  );
}

function GridLadderChart({
  status,
  quote,
  base,
}: {
  status: GridStatus;
  quote: string;
  base: string;
}) {
  type LadderRow = { price: number; amount: number; side: "buy" | "sell" };
  const rows = useMemo<LadderRow[]>(() => [
    ...status.sell_levels.map((l) => ({ price: l.price, amount: l.amount, side: "sell" as const })),
    ...status.buy_levels.map((l) => ({ price: l.price, amount: l.amount, side: "buy" as const })),
  ].sort((a, b) => b.price - a.price), [status.sell_levels, status.buy_levels]);

  if (rows.length === 0) return null;

  const maxAmount = useMemo(() => Math.max(...rows.map((r) => r.amount), 1), [rows]);
  const sellTotal = status.sell_levels.reduce((s, l) => s + l.amount, 0);
  const buyTotal  = status.buy_levels.reduce((s, l) => s + l.amount, 0);

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg overflow-hidden">
      {/* Header legend */}
      <div className="flex items-center justify-between px-3 py-1.5 bg-mempool-bg-elev border-b border-mempool-border">
        <span className="text-[9px] uppercase tracking-wider text-green-400 font-semibold">
          ↑ Buy {status.buy_levels.length} levels · {fmtBase(buyTotal, base)}
        </span>
        <span className="text-[9px] uppercase tracking-wider text-mempool-text-dim">ladder</span>
        <span className="text-[9px] uppercase tracking-wider text-orange-400 font-semibold">
          Sell {status.sell_levels.length} levels · {fmtBase(sellTotal, base)} ↓
        </span>
      </div>

      {/* Price ladder rows */}
      <div className="max-h-64 overflow-y-auto">
        {rows.map((r) => {
          const pct = (r.amount / maxAmount) * 100;
          const isSell = r.side === "sell";
          return (
            <div
              key={`${r.side}${r.price}`}
              className="relative flex items-center px-3 h-[22px] border-b border-mempool-border/30 last:border-b-0 hover:bg-mempool-bg-elev/40 transition-colors"
            >
              {/* Amount bar — fills from left for buy, from right for sell */}
              <div
                className={`absolute top-0 bottom-0 ${isSell ? "right-0" : "left-0"} opacity-20`}
                style={{
                  width: `${pct / 2}%`,
                  background: isSell ? "#f97316" : "#22c55e",
                }}
              />

              {/* Price */}
              <span
                className={`relative z-10 text-[10px] font-mono font-semibold flex-1 ${
                  isSell ? "text-orange-400" : "text-green-400"
                }`}
              >
                {fmtPrice(r.price, quote)}
              </span>

              {/* Side badge */}
              <span
                className={`relative z-10 text-[8px] uppercase tracking-wider px-1.5 rounded mr-2 flex-shrink-0 ${
                  isSell
                    ? "bg-orange-500/20 text-orange-300"
                    : "bg-green-500/20 text-green-300"
                }`}
              >
                {r.side}
              </span>

              {/* Amount */}
              <span className="relative z-10 text-[10px] font-mono text-mempool-text-dim w-28 text-right flex-shrink-0">
                {fmtBase(r.amount, base)}
              </span>
            </div>
          );
        })}
      </div>

      {/* Midpoint separator indicator */}
      <div className="flex items-center gap-2 px-3 py-1 bg-mempool-bg-elev border-t border-mempool-border">
        <div className="flex-1 h-px bg-mempool-border/60" />
        <span className="text-[9px] text-mempool-text-dim font-mono whitespace-nowrap">
          mid: {fmtPrice(Math.round((status.price_low + status.price_high) / 2), quote)}
        </span>
        <div className="flex-1 h-px bg-mempool-border/60" />
      </div>
    </div>
  );
}

function GridLevelsModal({ grid_id, pairs, onClose }: { grid_id: number; pairs: Pair[]; onClose: () => void }) {
  const [status, setStatus] = useState<GridStatus | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);

  useEffect(() => {
    rpc.gridStatus(grid_id).then(setStatus).catch((e: any) => setLoadErr(e?.message ?? String(e)));
  }, [grid_id]);

  const pair = pairs.find((p) => status && p.id === status.pair_id);
  const quote = pair?.quote ?? "USDC";
  const base = pair?.base ?? "OMNI";

  return (
    <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4 overflow-y-auto">
      <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl w-full max-w-lg p-4 sm:p-6 my-4">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-bold text-mempool-text uppercase tracking-wider">Grid #{grid_id} Levels</h2>
          <button onClick={onClose} className="text-mempool-text-dim hover:text-mempool-text text-lg">×</button>
        </div>
        {loadErr ? (
          <p className="text-red-400 text-xs font-mono text-center py-8">{loadErr}</p>
        ) : !status ? (
          <p className="text-mempool-text-dim text-sm text-center py-8 animate-pulse">Loading…</p>
        ) : (
          <div className="space-y-3">
            {/* Summary stats */}
            <div className="grid grid-cols-3 gap-2 text-[10px] bg-mempool-bg rounded-lg border border-mempool-border p-2">
              <div>
                <div className="text-mempool-text-dim">Range</div>
                <div className="font-mono text-mempool-text">{fmtPrice(status.price_low, quote)} – {fmtPrice(status.price_high, quote)}</div>
              </div>
              <div className="text-center">
                <div className="text-mempool-text-dim">Fills</div>
                <div className="font-mono text-mempool-blue">{status.filled_count}</div>
              </div>
              <div className="text-right">
                <div className="text-mempool-text-dim">Profit</div>
                <div className={`font-mono ${status.profit_quote >= 0 ? "text-green-400" : "text-red-400"}`}>
                  {status.profit_quote >= 0 ? "+" : ""}{(status.profit_quote / MICRO_PER_USD).toFixed(4)} {quote}
                </div>
              </div>
            </div>

            {/* Visual ladder chart */}
            <GridLadderChart status={status} quote={quote} base={base} />
          </div>
        )}
      </div>
    </div>
  );
}

export function GridPanel({ pairs, walletAddress }: { pairs: Pair[]; walletAddress: string }) {
  const [grids, setGrids] = useState<GridConfig[]>([]);
  const [loading, setLoading] = useState(true);
  const [showCreate, setShowCreate] = useState(false);
  const [detailGridId, setDetailGridId] = useState<number | null>(null);
  const [cancelling, setCancelling] = useState<number | null>(null);
  const [cancelErr, setCancelErr] = useState<string | null>(null);
  const [filterOwn, setFilterOwn] = useState(false);

  async function load() {
    setLoading(true);
    const list = await rpc.gridList();
    setGrids(list);
    setLoading(false);
  }

  useEffect(() => {
    void load();
    // Refresh on trade fills (grid fills emit new_trade) + 60s fallback.
    const unsub = wsSubscribe<WsNewTradeEvent>("new_trade", () => { void load(); });
    const id = setInterval(() => { void load(); }, 60_000);
    return () => { unsub(); clearInterval(id); };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function cancel(g: GridConfig) {
    if (!walletAddress) return;
    setCancelling(g.grid_id);
    setCancelErr(null);
    try {
      await rpc.gridCancel(g.grid_id, walletAddress);
      await load();
    } catch (e: any) {
      setCancelErr(e?.message ?? "Cancel failed");
    } finally {
      setCancelling(null);
    }
  }

  const displayed = filterOwn && walletAddress
    ? grids.filter((g) => g.owner === walletAddress)
    : grids;

  const activeCount = grids.filter((g) => g.active).length;

  return (
    <div className="space-y-4">
      {showCreate && (
        <CreateGridModal
          pairs={pairs}
          owner={walletAddress}
          onClose={() => setShowCreate(false)}
          onCreated={load}
        />
      )}
      {detailGridId !== null && (
        <GridLevelsModal
          grid_id={detailGridId}
          pairs={pairs}
          onClose={() => setDetailGridId(null)}
        />
      )}

      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div className="flex items-center gap-3">
          <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
            Grid Trading
          </h2>
          <span className="text-[10px] text-mempool-text-dim">
            {activeCount} active / {grids.length} total
          </span>
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          {walletAddress && (
            <label className="flex items-center gap-1 text-[11px] text-mempool-text-dim cursor-pointer">
              <input
                type="checkbox"
                checked={filterOwn}
                onChange={(e) => setFilterOwn(e.target.checked)}
                className="accent-mempool-blue"
              />
              My grids
            </label>
          )}
          {displayed.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["grid_id","pair","price_low","price_high","levels","fills","profit","status","owner"].join(","),
                  ...displayed.map((g) => {
                    const pair = pairs.find((p) => p.id === g.pair_id);
                    const quote = pair?.quote ?? "USDC";
                    return [
                      g.grid_id,
                      `"${pair?.label ?? `pair_${g.pair_id}`}"`,
                      (g.price_low / MICRO_PER_USD).toFixed(6),
                      (g.price_high / MICRO_PER_USD).toFixed(6),
                      g.levels,
                      g.filled_count,
                      (g.profit_quote / MICRO_PER_USD).toFixed(6) + " " + quote,
                      g.active ? "active" : "stopped",
                      `"${g.owner}"`,
                    ].join(",");
                  }),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = "omnibus-grids.csv";
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-2 py-1.5 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
            >
              ⬇ CSV
            </button>
          )}
          <button
            onClick={() => setShowCreate(true)}
            className="px-3 py-1.5 bg-mempool-blue hover:bg-blue-600 text-white text-xs rounded transition-colors"
          >
            + New Grid
          </button>
        </div>
      </div>

      {cancelErr && (
        <p className="text-xs text-red-400 font-mono px-1">{cancelErr}</p>
      )}

      <div className="text-[10px] text-mempool-text-dim bg-mempool-bg-elev rounded-lg p-3 border border-mempool-border">
        Grid = automated market making. Set price range + levels once — chain trades automatically using oracle prices.
        Funds stay in your wallet. <strong className="text-mempool-text">1 HTLC per fill</strong>, not per order.
      </div>

      {loading ? (
        <div className="text-center py-12 text-mempool-text-dim text-sm">Loading grids…</div>
      ) : displayed.length === 0 ? (
        <div className="text-center py-12 text-mempool-text-dim text-sm">
          {filterOwn ? "You have no grids." : "No grids yet."}{" "}
          <button onClick={() => setShowCreate(true)} className="text-mempool-blue hover:underline">Create one</button>
        </div>
      ) : (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full text-xs min-w-[640px]">
            <thead>
              <tr className="border-b border-mempool-border text-[10px] uppercase tracking-wider text-mempool-text-dim">
                <th className="text-left pb-2 pr-3">ID</th>
                <th className="text-left pb-2 pr-3">Pair</th>
                <th className="text-left pb-2 pr-3">Range</th>
                <th className="text-right pb-2 pr-3">Levels</th>
                <th className="text-right pb-2 pr-3">Fills</th>
                <th className="text-right pb-2 pr-3">Profit</th>
                <th className="text-center pb-2 pr-3">Status</th>
                <th className="text-right pb-2">Actions</th>
              </tr>
            </thead>
            <tbody>
              {displayed.map((g) => {
                const pair = pairs.find((p) => p.id === g.pair_id);
                const quote = pair?.quote ?? "USDC";
                const isOwner = walletAddress && g.owner === walletAddress;
                return (
                  <tr key={g.grid_id} className="border-b border-mempool-border/40 hover:bg-mempool-bg/30">
                    <td className="py-2 pr-3 font-mono text-mempool-text-dim">#{g.grid_id}</td>
                    <td className="py-2 pr-3 font-semibold text-mempool-text">{pair?.label ?? `pair_${g.pair_id}`}</td>
                    <td className="py-2 pr-3 font-mono text-mempool-text-dim">
                      {fmtPrice(g.price_low, quote)} – {fmtPrice(g.price_high, quote)}
                    </td>
                    <td className="py-2 pr-3 text-right text-mempool-text">{g.levels}×2</td>
                    <td className="py-2 pr-3 text-right text-mempool-text">{g.filled_count}</td>
                    <td className={`py-2 pr-3 text-right font-mono ${g.profit_quote >= 0 ? "text-green-400" : "text-red-400"}`}>
                      {g.profit_quote >= 0 ? "+" : ""}{(g.profit_quote / MICRO_PER_USD).toFixed(4)} {quote}
                    </td>
                    <td className="py-2 pr-3 text-center">
                      <span className={`px-2 py-0.5 rounded text-[10px] font-semibold ${g.active ? "bg-green-500/20 text-green-400" : "bg-mempool-bg text-mempool-text-dim"}`}>
                        {g.active ? "active" : "stopped"}
                      </span>
                    </td>
                    <td className="py-2 text-right">
                      <div className="flex justify-end gap-1">
                        <button
                          onClick={() => setDetailGridId(g.grid_id)}
                          className="px-2 py-1 text-[10px] rounded bg-mempool-bg hover:bg-mempool-bg-elev text-mempool-text-dim hover:text-mempool-text transition-colors"
                        >
                          Levels
                        </button>
                        {isOwner && g.active && (
                          <button
                            onClick={() => cancel(g)}
                            disabled={cancelling === g.grid_id}
                            className="px-2 py-1 text-[10px] rounded bg-orange-500/20 hover:bg-orange-500/30 text-orange-400 transition-colors disabled:opacity-50"
                          >
                            {cancelling === g.grid_id ? "…" : "Cancel"}
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {displayed.length > 0 && (
        <p className="text-[10px] text-mempool-text-dim">
          Grid fills use oracle price from price_oracle.zig · 1 HTLC per fill · funds move directly wallet→wallet via atomic swap
        </p>
      )}
    </div>
  );
}
