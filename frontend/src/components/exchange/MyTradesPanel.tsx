import { useEffect, useState } from "react";
import OmniBusRpcClient from "../../api/rpc-client";
import { AddressLabel } from "../common/AddressLabel";
import { getUnlocked, subscribeWallet } from "../../api/wallet-keystore";

const rpc = new OmniBusRpcClient();
const SAT_PER_OMNI = 1_000_000_000;
const MICRO_PER_USD = 1_000_000;

interface UserTrade {
  fillId: number;
  pairId: number;
  side: "buy" | "sell";
  counterparty: string;
  price: number;
  amount: number;
  buyOrderId: number;
  sellOrderId: number;
  blockHeight: number;
  ts: number;
  evmChainId: number;
  evmSettleTxHash: string | null;
}

const PAIR_LABELS: Record<number, string> = {
  0: "OMNI/USDC",
  2: "LCX/USDC",
  3: "ETH/USDC",
  5: "OMNI/LCX",
  6: "OMNI/ETH",
};

function explorerUrl(chainId: number, txHash: string): string | null {
  switch (chainId) {
    case 11155111: return `https://sepolia.etherscan.io/tx/${txHash}`;
    case 84532:    return `https://sepolia.basescan.org/tx/${txHash}`;
    case 8888:     return `https://explorer.lcx.com/tx/${txHash}`;
    case 1:        return `https://etherscan.io/tx/${txHash}`;
    case 8453:     return `https://basescan.org/tx/${txHash}`;
    default:       return null;
  }
}

function shortAddr(a: string): string {
  if (a.length <= 14) return a;
  return `${a.slice(0, 8)}…${a.slice(-4)}`;
}

interface Props {
  pairId?: number;
  refreshKey?: number;
}

/**
 * MyTradesPanel — istoric on-chain de fills al traderului unlocked.
 *
 * Pe spate folosește `exchange_getUserTrades` care citește fills_log.bin
 * persistent de pe disk. Asta înseamnă că la restart de frontend (sau de
 * node) istoricul rămâne intact — nimic nu trăiește doar în UI.
 *
 * Pentru pair-uri cross-chain (OMNI/USDC, OMNI/ETH) afișează și link la
 * tx-ul EVM de settle (Sepolia/Base) când settler-ul l-a confirmat.
 */
export function MyTradesPanel({ pairId, refreshKey }: Props) {
  const [, force] = useState(0);
  useEffect(() => subscribeWallet(() => force((n) => n + 1)), []);

  const [trades, setTrades] = useState<UserTrade[]>([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  const u = getUnlocked();

  useEffect(() => {
    if (!u) {
      setTrades([]);
      setLoading(false);
      return;
    }
    let cancelled = false;
    const refresh = async () => {
      try {
        const params: { trader: string; limit: number; pairId?: number } = {
          trader: u.address,
          limit: 100,
        };
        if (pairId !== undefined) params.pairId = pairId;
        const result = await rpc.request_raw("exchange_getUserTrades", [params]);
        if (!cancelled && Array.isArray(result)) {
          setTrades(result as UserTrade[]);
          setErr(null);
        }
        if (!cancelled) setLoading(false);
      } catch (e: any) {
        if (!cancelled) {
          setErr(e?.message ?? String(e));
          setLoading(false);
        }
      }
    };
    refresh();
    const id = setInterval(refresh, 6000);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [u?.address, pairId, refreshKey]);

  if (!u) {
    return (
      <div className="rounded-lg border border-mempool-border bg-mempool-bg p-3">
        <div className="text-[10px] text-mempool-text-dim">Unlock wallet to see your trade history</div>
      </div>
    );
  }

  return (
    <div className="rounded-lg border border-mempool-border bg-mempool-bg p-3">
      <div className="text-[9px] uppercase tracking-wider text-mempool-text-dim mb-2 flex items-center gap-1.5">
        <span className="text-mempool-text font-semibold">My Trades</span>
        <span className="text-mempool-border">·</span>
        <span>on-chain history{pairId !== undefined ? ` · ${PAIR_LABELS[pairId] ?? `pair ${pairId}`}` : ""}</span>
        {trades.length > 0 && (
          <>
            <span className="ml-auto text-mempool-text-dim/70 text-[8px]">{trades.length} fills</span>
            <button
              onClick={() => {
                const rows = [
                  ["fill_id","pair","side","price_usd","amount_omni","counterparty","block_height","timestamp","settle_tx_hash","settle_chain_id"].join(","),
                  ...trades.map((t) => [
                    t.fillId,
                    PAIR_LABELS[t.pairId] ?? `pair ${t.pairId}`,
                    t.side,
                    (t.price / MICRO_PER_USD).toFixed(6),
                    (t.amount / SAT_PER_OMNI).toFixed(8),
                    `"${t.counterparty}"`,
                    t.blockHeight,
                    new Date(t.ts).toISOString(),
                    t.evmSettleTxHash ? `"${t.evmSettleTxHash}"` : "",
                    t.evmChainId || "",
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = `omnibus-my-trades.csv`;
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-1.5 py-0.5 text-[8px] rounded border border-mempool-border/50 text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
            >
              ⬇ CSV
            </button>
          </>
        )}
      </div>

      {err && (
        <div className="text-[10px] text-red-400 mb-2">Error: {err}</div>
      )}

      {loading && (
        <div className="text-[10px] text-mempool-text-dim animate-pulse">loading…</div>
      )}

      {!loading && trades.length === 0 && !err && (
        <div className="text-[10px] text-mempool-text-dim">No trades yet for this wallet.</div>
      )}

      {trades.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full text-[10px] font-mono">
            <thead>
              <tr className="text-mempool-text-dim text-[8px] uppercase tracking-wider">
                <th className="text-left py-1 pr-2">Time</th>
                <th className="text-left py-1 pr-2">Pair</th>
                <th className="text-left py-1 pr-2">Side</th>
                <th className="text-right py-1 pr-2">Price</th>
                <th className="text-right py-1 pr-2">Amount</th>
                <th className="text-left py-1 pr-2">Counterparty</th>
                <th className="text-right py-1 pr-2">Block</th>
                <th className="text-left py-1">Settle TX</th>
              </tr>
            </thead>
            <tbody>
              {trades.map((t) => {
                const date = new Date(t.ts);
                const timeStr = `${date.toLocaleDateString()} ${date.toLocaleTimeString()}`;
                const pairLabel = PAIR_LABELS[t.pairId] ?? `pair ${t.pairId}`;
                const priceUsd = t.price / MICRO_PER_USD;
                const amtOmni = t.amount / SAT_PER_OMNI;
                const sideColor = t.side === "buy" ? "text-green-400" : "text-red-400";
                const settleUrl = t.evmSettleTxHash && t.evmChainId
                  ? explorerUrl(t.evmChainId, t.evmSettleTxHash)
                  : null;

                return (
                  <tr key={t.fillId} className="border-t border-mempool-border/40">
                    <td className="py-1 pr-2 text-mempool-text-dim">{timeStr}</td>
                    <td className="py-1 pr-2">{pairLabel}</td>
                    <td className={`py-1 pr-2 uppercase font-semibold ${sideColor}`}>{t.side}</td>
                    <td className="py-1 pr-2 text-right">{priceUsd.toFixed(4)}</td>
                    <td className="py-1 pr-2 text-right">{amtOmni.toFixed(4)}</td>
                    <td className="py-1 pr-2 text-mempool-text-dim" title={t.counterparty}>
                      <button onClick={() => { if (t.counterparty) window.location.hash = `#/address/${t.counterparty}`; }} className="hover:text-mempool-blue hover:underline transition-colors">
                        <AddressLabel address={t.counterparty ?? ""} showEmoji truncate={{ left: 8, right: 5 }} />
                      </button>
                    </td>
                    <td className="py-1 pr-2 text-right text-mempool-text-dim">{t.blockHeight}</td>
                    <td className="py-1">
                      {settleUrl ? (
                        <a
                          href={settleUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="text-blue-400 hover:underline"
                          title={t.evmSettleTxHash ?? undefined}
                        >
                          {shortAddr(t.evmSettleTxHash ?? "")}
                        </a>
                      ) : t.evmChainId ? (
                        <span className="text-yellow-400/70" title="waiting for settler to submit on EVM">
                          pending
                        </span>
                      ) : (
                        <span className="text-mempool-text-dim">—</span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
