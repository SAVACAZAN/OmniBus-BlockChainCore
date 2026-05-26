import { useState, useEffect, useRef, useCallback, useMemo } from "react";
import { useBlockchain } from "../../stores/useBlockchainStore";
import { rpc } from "../../api/rpc-client";
import type { BlockData } from "../../types";
import { AddressLabel } from "../common/AddressLabel";
import { midTrunc, fmtAge, SAT_PER_OMNI } from "../../utils/fmt";
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
} from "recharts";


type BlockWithDiff = BlockData & { difficulty?: number; totalFees?: number };

const BLOCK_HISTORY_SIZES = ["10", "20", "50", "100", "500", "2000"] as const;

function BlockIntervalCell({ height, timestamp, tsMap }: { height: number; timestamp?: number; tsMap: Map<number, number> }) {
  const prevTs = tsMap.get(height + 1);
  if (!prevTs || !timestamp) return <span className="text-mempool-text-dim">—</span>;
  const d = prevTs - timestamp;
  const cls = d <= 0 || d > 60 ? "text-mempool-text-dim" : d < 8 ? "text-orange-400" : d <= 15 ? "text-green-400" : "text-yellow-400";
  return <span className={`font-mono ${cls}`}>{Math.abs(d)}s</span>;
}

export function BlocksPage() {
  const { state } = useBlockchain();
  const [blocks, setBlocks] = useState<BlockWithDiff[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [page, setPage] = useState(0);
  const [jumpInput, setJumpInput] = useState("");
  const PAGE_SIZE = 20;

  // Reload when page changes OR a new block arrives (state.blockCount is WS-driven).
  useEffect(() => {
    loadBlocks();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, state.blockCount]);

  const loadBlocks = async () => {
    setLoading(true);
    setLoadErr(null);
    try {
      let height = state.blockCount;
      try {
        const liveCount = await rpc.getBlockCount();
        if (liveCount > 0) height = liveCount;
      } catch { /* fall back */ }

      // Use getblocks (1 call) instead of N individual getBlock calls.
      // getblocks returns blocks ascending from `from`; we reverse for display.
      const from = Math.max(0, height - (page + 1) * PAGE_SIZE);
      const count = Math.min(PAGE_SIZE, height - from);
      if (count <= 0) { setBlocks([]); setLoading(false); return; }

      try {
        const blks = await rpc.getBlocks(from, count);
        setBlocks([...blks].reverse() as BlockWithDiff[]);
      } catch {
        // Fallback to individual requests if getblocks not available
        const start = Math.max(0, height - 1 - page * PAGE_SIZE);
        const end = Math.max(0, start - PAGE_SIZE);
        const indices: number[] = [];
        for (let i = start; i > end && i >= 0; i--) indices.push(i);
        const results = await Promise.all(
          indices.map((idx) => rpc.getBlock(idx).catch(() => null))
        );
        setBlocks(results.filter(Boolean) as BlockWithDiff[]);
      }
    } catch (e: any) {
      setLoadErr(e?.message || "Failed to load blocks");
    }
    setLoading(false);
  };

  const maxPage = Math.max(0, Math.floor((state.blockCount - 1) / PAGE_SIZE));

  const tsMap = useMemo(() => new Map(blocks.map((b) => [b.height, b.timestamp])), [blocks]);
  const maxTxCount = useMemo(() => Math.max(1, ...blocks.map((b) => b.txCount || 0)), [blocks]);
  const chartData = useMemo(() =>
    [...blocks].reverse().map((b) => ({ h: b.height, d: b.difficulty ?? b.nonce ?? 0 })),
  [blocks]);
  const hasDifficulty = useMemo(() => chartData.some((c) => c.d > 0), [chartData]);

  return (
    <div className="max-w-7xl mx-auto px-4 py-6 space-y-4">
      {/* Title + pagination */}
      <div className="flex items-center justify-between flex-wrap gap-2">
        <h2 className="text-lg font-bold text-mempool-text">
          Blocks{" "}
          <span className="text-mempool-text-dim font-normal text-sm">
            ({state.blockCount.toLocaleString()} total)
          </span>
        </h2>
        <div className="flex items-center gap-2 flex-wrap">
          {/* Jump to block */}
          <form
            className="flex items-center gap-1"
            onSubmit={(e) => {
              e.preventDefault();
              const n = parseInt(jumpInput.trim(), 10);
              if (!isNaN(n) && n >= 0) {
                window.location.hash = `#/block/${n}`;
                setJumpInput("");
              }
            }}
          >
            <input
              type="number"
              min="0"
              max={state.blockCount}
              value={jumpInput}
              onChange={(e) => setJumpInput(e.target.value)}
              placeholder="Go to #…"
              className="w-24 px-2 py-1 text-xs bg-mempool-bg border border-mempool-border rounded font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
            />
            <button
              type="submit"
              className="px-2 py-1 text-xs bg-mempool-bg-elev border border-mempool-border rounded hover:bg-mempool-bg-light text-mempool-text-dim transition-colors"
            >
              ↵
            </button>
          </form>

          {blocks.length > 0 && (
            <button
              onClick={() => {
                const rows = [
                  ["height", "hash", "miner", "tx_count", "reward_omni", "fees_omni", "timestamp"].join(","),
                  ...blocks.map((b) => [
                    b.height,
                    `"${b.hash}"`,
                    `"${b.miner ?? ""}"`,
                    (b.txCount || 0) + 1,
                    ((b.rewardSAT || 0) / SAT_PER_OMNI).toFixed(8),
                    ((b.totalFees ?? 0) > 0 ? ((b.totalFees! / SAT_PER_OMNI).toFixed(8)) : "0"),
                    b.timestamp ?? "",
                  ].join(",")),
                ].join("\n");
                const blob = new Blob([rows], { type: "text/csv" });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url; a.download = `omnibus-blocks-p${page + 1}.csv`;
                a.click(); URL.revokeObjectURL(url);
              }}
              className="px-3 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue font-mono"
            >
              ⬇ CSV
            </button>
          )}
          <button
            onClick={() => setPage(Math.min(page + 1, maxPage))}
            disabled={page >= maxPage}
            className="px-3 py-1 text-xs bg-mempool-bg-elev border border-mempool-border rounded hover:bg-mempool-bg-light disabled:opacity-30 text-mempool-text-dim transition-colors"
          >
            Older
          </button>
          <span className="text-xs text-mempool-text-dim">Page {page + 1}</span>
          <button
            onClick={() => setPage(Math.max(0, page - 1))}
            disabled={page <= 0}
            className="px-3 py-1 text-xs bg-mempool-bg-elev border border-mempool-border rounded hover:bg-mempool-bg-light disabled:opacity-30 text-mempool-text-dim transition-colors"
          >
            Newer
          </button>
        </div>
      </div>

      {/* Difficulty / nonce sparkline chart */}
      {hasDifficulty && (
        <div className="bg-mempool-bg-elev border border-mempool-border rounded-xl p-4">
          <div className="flex items-center justify-between mb-2">
            <span className="text-[10px] font-semibold uppercase tracking-widest text-mempool-text-dim">
              Difficulty (last {chartData.length} blocks)
            </span>
          </div>
          <ResponsiveContainer width="100%" height={80}>
            <LineChart data={chartData} margin={{ top: 4, right: 8, left: 0, bottom: 0 }}>
              <XAxis dataKey="h" hide />
              <YAxis hide domain={["auto", "auto"]} />
              <Tooltip
                contentStyle={{
                  background: "var(--color-mempool-bg-elev, #1a1b1e)",
                  border: "1px solid var(--color-mempool-border, #2d2f36)",
                  borderRadius: "6px",
                  fontSize: "11px",
                  color: "#c9d1d9",
                }}
                labelFormatter={(v) => `Block #${v}`}
                formatter={(v: number) => [v.toLocaleString(), "Difficulty"]}
              />
              <Line
                type="monotone"
                dataKey="d"
                stroke="#3b82f6"
                strokeWidth={1.5}
                dot={false}
                activeDot={{ r: 3, fill: "#3b82f6" }}
              />
            </LineChart>
          </ResponsiveContainer>
        </div>
      )}

      {/* Blocks table */}
      <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border overflow-x-auto">
        <table className="w-full text-xs min-w-[480px]">
          <thead>
            <tr className="text-mempool-text-dim border-b border-mempool-border text-left">
              <th className="px-4 py-3 font-medium">Height</th>
              <th className="px-4 py-3 font-medium">Hash</th>
              <th className="px-4 py-3 font-medium">Miner</th>
              <th className="px-4 py-3 font-medium text-right">TXs</th>
              <th className="px-4 py-3 font-medium text-right">Reward</th>
              <th className="px-4 py-3 font-medium text-right">Fees</th>
              <th className="px-4 py-3 font-medium text-right">Δt</th>
              <th className="px-4 py-3 font-medium text-right">Time</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-mempool-border/30">
            {loading ? (
              <tr>
                <td colSpan={8} className="px-4 py-8 text-center text-mempool-text-dim">
                  Loading…
                </td>
              </tr>
            ) : loadErr ? (
              <tr>
                <td colSpan={8} className="px-4 py-8 text-center text-red-400 text-xs font-mono">
                  {loadErr}
                </td>
              </tr>
            ) : blocks.length === 0 ? (
              <tr>
                <td colSpan={8} className="px-4 py-8 text-center text-mempool-text-dim">
                  No blocks
                </td>
              </tr>
            ) : (
              blocks.map((b) => (
                <tr
                  key={`block-${b.height}`}
                  className="hover:bg-mempool-bg-light/50 transition-colors cursor-pointer"
                  onClick={() => { window.location.hash = `#/block/${b.height}`; }}
                  title={`Open block #${b.height}`}
                >
                  <td className="px-4 py-2.5 font-mono text-mempool-blue font-bold whitespace-nowrap">
                    #{b.height.toLocaleString()}
                  </td>
                  <td className="px-4 py-2.5 font-mono text-mempool-text whitespace-nowrap" title={b.hash}>
                    {midTrunc(b.hash, 8, 6)}
                  </td>
                  <td
                    className="px-4 py-2.5 font-mono text-mempool-text-dim whitespace-nowrap hover:text-mempool-blue transition-colors"
                    title={b.miner}
                    onClick={(e) => {
                      if (b.miner) {
                        e.stopPropagation();
                        window.location.hash = `#/address/${b.miner}`;
                      }
                    }}
                  >
                    <AddressLabel address={b.miner ?? ""} showEmoji truncate={{ left: 8, right: 6 }} />
                  </td>
                  <td className="px-4 py-2.5 text-right whitespace-nowrap">
                    <div className="flex items-center justify-end gap-1.5">
                      <div className="w-12 h-1.5 bg-mempool-bg rounded-full overflow-hidden flex-shrink-0">
                        <div
                          className="h-full rounded-full bg-green-400"
                          style={{ width: `${Math.min(100, ((b.txCount || 0) / maxTxCount) * 100)}%` }}
                        />
                      </div>
                      <span className="font-mono text-mempool-text">{(b.txCount || 0) + 1}</span>
                    </div>
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-green whitespace-nowrap">
                    {((b.rewardSAT || 0) / SAT_PER_OMNI).toFixed(8)}
                  </td>
                  <td className="px-4 py-2.5 text-right font-mono text-mempool-text-dim whitespace-nowrap">
                    {(b.totalFees ?? 0) > 0
                      ? <span className="text-purple-300">{(b.totalFees! / SAT_PER_OMNI).toFixed(8)}</span>
                      : <span>—</span>}
                  </td>
                  <td className="px-4 py-2.5 text-right whitespace-nowrap">
                    <BlockIntervalCell height={b.height} timestamp={b.timestamp} tsMap={tsMap} />
                  </td>
                  <td className="px-4 py-2.5 text-right text-mempool-text-dim whitespace-nowrap"
                      title={b.timestamp ? new Date(b.timestamp * 1000).toLocaleString() : undefined}>
                    {b.timestamp ? fmtAge(b.timestamp) : "—"}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      <SpvPanel />
      <BlockHashPanel />
    </div>
  );
}

// ---------------------------------------------------------------------------
// SPV Panel — getheaders + getmerkleproof
// ---------------------------------------------------------------------------

interface BlockHeader {
  height: number;
  timestamp: number;
  hash: string;
  previousHash: string;
  merkleRoot: string;
  nonce: number;
  difficulty: number;
  txCount: number;
}

interface GetHeadersResp {
  from: number;
  count: number;
  headers: BlockHeader[];
}

interface MerkleProofEntry {
  hash: string;
  direction: "left" | "right";
}

interface MerkleProofResp {
  blockHeight: number;
  txIndex: number;
  merkleRoot: string;
  proof: MerkleProofEntry[];
}

function SpvPanel() {
  const [spvTab, setSpvTab] = useState<"headers" | "proof">("headers");

  // Headers state
  const [hFrom, setHFrom] = useState("");
  const [hCount, setHCount] = useState("10");
  const [headers, setHeaders] = useState<BlockHeader[] | null>(null);
  const [hLoading, setHLoading] = useState(false);
  const [hErr, setHErr] = useState<string | null>(null);

  // Proof state
  const [pHeight, setPHeight] = useState("");
  const [pTxIndex, setPTxIndex] = useState("");
  const [proof, setProof] = useState<MerkleProofResp | null>(null);
  const [pLoading, setPLoading] = useState(false);
  const [pErr, setPErr] = useState<string | null>(null);

  const abortRef = useRef<AbortController | null>(null);

  const onFetchHeaders = async () => {
    if (!hFrom) return;
    setHLoading(true);
    setHErr(null);
    setHeaders(null);
    try {
      const r = (await rpc.getHeaders(
        parseInt(hFrom, 10),
        parseInt(hCount, 10) || 10,
      )) as GetHeadersResp;
      setHeaders(Array.isArray(r?.headers) ? r.headers : []);
    } catch (e: any) {
      setHErr(e?.message ?? String(e));
    } finally {
      setHLoading(false);
    }
  };

  const onFetchProof = async () => {
    if (!pHeight || !pTxIndex) return;
    setPLoading(true);
    setPErr(null);
    setProof(null);
    try {
      const r = (await rpc.getMerkleProofByIndex(
        parseInt(pHeight, 10),
        parseInt(pTxIndex, 10),
      )) as MerkleProofResp;
      setProof(r);
    } catch (e: any) {
      setPErr(e?.message ?? String(e));
    } finally {
      setPLoading(false);
    }
  };

  void abortRef; // suppress unused warning

  return (
    <div className="bg-mempool-bg-elev rounded-xl border border-mempool-border p-4 space-y-4">
      <div className="flex items-center justify-between flex-wrap gap-2">
        <h3 className="text-sm font-semibold text-mempool-text">SPV — Light Client Tools</h3>
        <div className="flex gap-1">
          {(["headers", "proof"] as const).map((t) => (
            <button
              key={t}
              onClick={() => setSpvTab(t)}
              className={`px-3 py-1 text-xs rounded ${
                spvTab === t
                  ? "bg-mempool-blue text-white"
                  : "bg-mempool-bg text-mempool-text-dim border border-mempool-border hover:text-mempool-text"
              }`}
            >
              {t === "headers" ? "Get Headers" : "Merkle Proof"}
            </button>
          ))}
        </div>
      </div>

      {spvTab === "headers" && (
        <div className="space-y-3">
          <p className="text-[11px] text-mempool-text-dim">
            Download a range of block headers for SPV verification (max 2000 per request).
          </p>
          <div className="flex gap-2 flex-wrap items-end">
            <div>
              <label className="text-[10px] text-mempool-text-dim block mb-0.5 uppercase">From height</label>
              <input
                value={hFrom}
                onChange={(e) => setHFrom(e.target.value)}
                type="number"
                min="0"
                className="w-28 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
                placeholder="0"
              />
            </div>
            <div>
              <label className="text-[10px] text-mempool-text-dim block mb-0.5 uppercase">Count</label>
              <select
                value={hCount}
                onChange={(e) => setHCount(e.target.value)}
                className="bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs text-mempool-text"
              >
                {BLOCK_HISTORY_SIZES.map((n) => (
                  <option key={n} value={n}>{n}</option>
                ))}
              </select>
            </div>
            <button
              onClick={onFetchHeaders}
              disabled={hLoading || !hFrom}
              className="px-3 py-1.5 text-xs bg-mempool-blue/20 hover:bg-mempool-blue/40 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50"
            >
              {hLoading ? "Fetching…" : "Fetch Headers"}
            </button>
          </div>
          {hErr && <p className="text-xs text-red-400">{hErr}</p>}
          {headers && (
            <div className="overflow-x-auto rounded border border-mempool-border">
              <table className="w-full text-[10px] min-w-[640px]">
                <thead className="bg-mempool-bg text-mempool-text-dim uppercase">
                  <tr>
                    <th className="px-2 py-1.5 text-right">Height</th>
                    <th className="px-2 py-1.5 text-left">Hash</th>
                    <th className="px-2 py-1.5 text-left">Prev Hash</th>
                    <th className="px-2 py-1.5 text-left">Merkle Root</th>
                    <th className="px-2 py-1.5 text-right">Nonce</th>
                    <th className="px-2 py-1.5 text-right">TXs</th>
                    <th className="px-2 py-1.5 text-right">Time</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-mempool-border/30">
                  {headers.map((h) => (
                    <tr key={h.height} className="hover:bg-mempool-bg-light/50">
                      <td className="px-2 py-1.5 text-right font-mono text-mempool-blue">{h.height}</td>
                      <td className="px-2 py-1.5 font-mono text-mempool-text" title={h.hash}>{midTrunc(h.hash)}</td>
                      <td className="px-2 py-1.5 font-mono text-mempool-text-dim" title={h.previousHash}>{midTrunc(h.previousHash)}</td>
                      <td className="px-2 py-1.5 font-mono text-mempool-text-dim" title={h.merkleRoot}>{midTrunc(h.merkleRoot)}</td>
                      <td className="px-2 py-1.5 text-right font-mono text-mempool-text-dim">{h.nonce}</td>
                      <td className="px-2 py-1.5 text-right font-mono text-mempool-text">{h.txCount}</td>
                      <td className="px-2 py-1.5 text-right text-mempool-text-dim whitespace-nowrap"
                          title={h.timestamp ? new Date(h.timestamp * 1000).toLocaleString() : undefined}>
                        {h.timestamp ? fmtAge(h.timestamp) : "—"}
                      </td>
                    </tr>
                  ))}
                  {headers.length === 0 && (
                    <tr><td colSpan={7} className="text-center py-4 text-mempool-text-dim">No headers returned.</td></tr>
                  )}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}

      {spvTab === "proof" && (
        <div className="space-y-3">
          <p className="text-[11px] text-mempool-text-dim">
            Fetch the Merkle inclusion proof for a TX at a given block height and index.
          </p>
          <div className="flex gap-2 flex-wrap items-end">
            <div>
              <label className="text-[10px] text-mempool-text-dim block mb-0.5 uppercase">Block height</label>
              <input
                value={pHeight}
                onChange={(e) => setPHeight(e.target.value)}
                type="number"
                min="0"
                className="w-28 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
                placeholder="1234"
              />
            </div>
            <div>
              <label className="text-[10px] text-mempool-text-dim block mb-0.5 uppercase">TX index</label>
              <input
                value={pTxIndex}
                onChange={(e) => setPTxIndex(e.target.value)}
                type="number"
                min="0"
                className="w-20 bg-mempool-bg border border-mempool-border rounded px-2 py-1.5 text-xs font-mono text-mempool-text"
                placeholder="0"
              />
            </div>
            <button
              onClick={onFetchProof}
              disabled={pLoading || !pHeight || !pTxIndex}
              className="px-3 py-1.5 text-xs bg-green-500/20 hover:bg-green-500/30 text-green-300 border border-green-500/30 rounded disabled:opacity-50"
            >
              {pLoading ? "Fetching…" : "Get Proof"}
            </button>
          </div>
          {pErr && <p className="text-xs text-red-400">{pErr}</p>}
          {proof && (
            <div className="space-y-2">
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-2 text-[11px] font-mono">
                <div className="bg-mempool-bg rounded p-2">
                  <div className="text-mempool-text-dim text-[9px] uppercase mb-0.5">Block</div>
                  <div className="text-mempool-blue">{proof.blockHeight}</div>
                </div>
                <div className="bg-mempool-bg rounded p-2">
                  <div className="text-mempool-text-dim text-[9px] uppercase mb-0.5">TX index</div>
                  <div className="text-mempool-text">{proof.txIndex}</div>
                </div>
                <div className="bg-mempool-bg rounded p-2 col-span-2 sm:col-span-1">
                  <div className="text-mempool-text-dim text-[9px] uppercase mb-0.5">Merkle Root</div>
                  <div className="text-mempool-text break-all text-[9px]">{proof.merkleRoot}</div>
                </div>
              </div>
              <div className="rounded border border-mempool-border overflow-hidden">
                <div className="px-3 py-1.5 bg-mempool-bg text-[9px] uppercase text-mempool-text-dim font-semibold">
                  Proof path ({(proof.proof ?? []).length} hops)
                </div>
                <div className="divide-y divide-mempool-border/30">
                  {(proof.proof ?? []).map((p, i) => (
                    <div key={i} className="flex items-center gap-3 px-3 py-1.5 text-[10px] font-mono">
                      <span className={`text-[9px] px-1.5 py-0.5 rounded ${
                        p.direction === "left"
                          ? "bg-blue-500/10 text-blue-400"
                          : "bg-orange-500/10 text-orange-400"
                      }`}>
                        {p.direction}
                      </span>
                      <span className="text-mempool-text-dim break-all">{p.hash}</span>
                    </div>
                  ))}
                  {(proof.proof ?? []).length === 0 && (
                    <div className="px-3 py-3 text-center text-mempool-text-dim text-[11px]">
                      TX is the only TX in this block (trivial proof).
                    </div>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Block Hash Lookup (getblockhash + getbestblockhash) ───────────────────────

function BlockHashPanel() {
  const [bestHash, setBestHash] = useState<string | null>(null);
  const [lookupHeight, setLookupHeight] = useState("");
  const [lookupHash, setLookupHash] = useState<string | null>(null);
  const [lookupErr, setLookupErr] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    rpc.getBestBlockHash()
      .then((r) => { if (r) setBestHash(r); })
      .catch(() => {});
  }, []);

  const lookupByHeight = useCallback(async () => {
    const h = parseInt(lookupHeight, 10);
    if (isNaN(h) || h < 0) { setLookupErr("Enter a valid block height"); return; }
    setLoading(true); setLookupErr(""); setLookupHash(null);
    try {
      const r = await rpc.getBlockHash(h);
      if (r) setLookupHash(r);
      else setLookupErr("Block not found");
    } catch (e) { setLookupErr(String(e)); }
    finally { setLoading(false); }
  }, [lookupHeight]);

  return (
    <div className="mt-4 rounded-xl border border-mempool-border bg-mempool-bg-elev p-4 space-y-4">
      <h3 className="text-xs font-semibold text-mempool-text-dim uppercase tracking-wider">
        Block Hash Utilities
      </h3>

      {/* Best block hash */}
      <div className="space-y-1">
        <div className="text-[10px] uppercase text-mempool-text-dim">Best Block Hash (getbestblockhash)</div>
        {bestHash ? (
          <div className="font-mono text-xs text-mempool-blue break-all bg-mempool-bg rounded p-2">
            {bestHash}
          </div>
        ) : (
          <div className="text-xs text-mempool-text-dim italic">Loading…</div>
        )}
      </div>

      {/* Block hash by height */}
      <div className="space-y-2">
        <div className="text-[10px] uppercase text-mempool-text-dim">Block Hash by Height (getblockhash)</div>
        <div className="flex gap-2">
          <input
            type="number"
            min="0"
            value={lookupHeight}
            onChange={(e) => setLookupHeight(e.target.value)}
            placeholder="Block height"
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-1.5 text-xs font-mono text-mempool-text"
          />
          <button
            onClick={lookupByHeight}
            disabled={loading || !lookupHeight}
            className="px-4 py-1.5 text-xs font-medium bg-mempool-blue/20 hover:bg-mempool-blue/40 text-mempool-blue border border-mempool-blue/30 rounded disabled:opacity-50"
          >
            {loading ? "…" : "Get Hash"}
          </button>
        </div>
        {lookupErr && <p className="text-xs text-red-400">{lookupErr}</p>}
        {lookupHash && (
          <div className="font-mono text-xs text-mempool-green break-all bg-mempool-bg rounded p-2">
            {lookupHash}
          </div>
        )}
      </div>
    </div>
  );
}
