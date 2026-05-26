/**
 * ChannelsPage.tsx — Payment channels (off-chain micropayments).
 *
 * Payment channels allow instant off-chain micropayments between two parties,
 * similar to Lightning Network. Both parties lock OMNI into a channel and can
 * exchange signed state updates without touching the blockchain until close.
 *
 * Backend RPCs:
 *   - getchannels   [] | [pubkey_hex_66]
 *   - openchannel   [pubkeyA, pubkeyB, amountA_sat, amountB_sat]
 *   - channelpay    [channel_id, direction, amount_sat, sig_a, sig_b]
 *   - closechannel  [channel_id, sig_a, sig_b]
 *
 * Signing messages match backend verify path (SHA256d + secp256k1).
 * For testnet/demo both sig_a and sig_b use the same wallet key.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { subscribe as wsSubscribe } from "../../api/ws-bus";
import type { WsNewBlockEvent } from "../../types";
import {
  Zap,
  RefreshCw,
  ArrowRight,
  ArrowLeft,
  AlertTriangle,
  Info,
  CheckCircle2,
  XCircle,
  Clock,
} from "lucide-react";
import * as secp from "@noble/secp256k1";
import { OmniBusRpcClient } from "../../api/rpc-client";
import { useWallet } from "../../api/use-wallet";
import { CopyButton } from "../common/CopyButton";
import { satToOmni, SAT_PER_OMNI, midTrunc } from "../../utils/fmt";
import { bytesToHex, hexToBytes, signMessage } from "../../api/exchange-sign";

const rpc = new OmniBusRpcClient();

// ── SAT / OMNI helpers ──────────────────────────────────────────────────────

const toOMNI = (sat: number) => satToOmni(sat, 8);
const toSAT = (omni: number) => Math.round(omni * SAT_PER_OMNI);

const intFmt = new Intl.NumberFormat("en-US");

// ── Types ────────────────────────────────────────────────────────────────────

type ChannelState = "open" | "closing" | "settled" | "disputed";
type SubTab = "overview" | "open" | "pay" | "close";

interface Channel {
  channel_id: string;    // 64-char hex
  party_a: string;       // 66-char compressed pubkey hex
  party_b: string;       // 66-char compressed pubkey hex
  capacity_sat: number;
  balance_a: number;
  balance_b: number;
  sequence_num: number;
  state: ChannelState;
}

interface ChannelsSummary {
  open_count: number;
  closing_count: number;
  settled_count: number;
  disputed_count: number;
  total_locked_sat: number;
}

interface GetChannelsResp {
  summary: ChannelsSummary;
  channels: Channel[];
}

interface OpenChannelResp {
  channel_id: string;
  balance_a: number;
  balance_b: number;
  total_locked: number;
  state: "open";
}

interface ChannelPayResp {
  sequence_num: number;
  balance_a: number;
  balance_b: number;
}

interface CloseChannelResp {
  state: "settled";
  final_balance_a: number;
  final_balance_b: number;
  tx_hash_a: string;
  tx_hash_b: string;
}

// ── Signing ──────────────────────────────────────────────────────────────────

function signChannelPay(args: {
  privateKeyHex: string;
  channelId: string;
  direction: "a_to_b" | "b_to_a";
  amount: number;
  nextSeq: number;
}): string {
  const msg = `CHANNEL_PAY_V1\n${args.channelId}\n${args.direction}\n${args.amount}\n${args.nextSeq}`;
  return signMessage(args.privateKeyHex, msg).signature;
}

function signChannelClose(args: {
  privateKeyHex: string;
  channelId: string;
}): string {
  const msg = `CHANNEL_CLOSE_V1\n${args.channelId}`;
  return signMessage(args.privateKeyHex, msg).signature;
}

function getPubkeyFromPrivkey(privKeyHex: string): string {
  if (privKeyHex.startsWith("0x")) privKeyHex = privKeyHex.slice(2);
  const priv = hexToBytes(privKeyHex);
  const pub = secp.getPublicKey(priv, true);
  return bytesToHex(pub);
}

// ── Format helpers ────────────────────────────────────────────────────────────

function shortPubkey(pk: string): string {
  return pk.length > 8 ? pk.slice(0, 8) : pk;
}

// ── State badge ───────────────────────────────────────────────────────────────

function StateBadge({ state }: { state: ChannelState }) {
  const cls = (() => {
    switch (state) {
      case "open":     return "bg-green-500/20 text-green-400 border-green-500/40";
      case "closing":  return "bg-yellow-500/20 text-yellow-400 border-yellow-500/40";
      case "settled":  return "bg-gray-500/20 text-gray-400 border-gray-500/40";
      case "disputed": return "bg-red-500/20 text-red-400 border-red-500/40";
      default:         return "bg-gray-500/20 text-gray-400 border-gray-500/40";
    }
  })();
  return (
    <span className={`text-[10px] uppercase tracking-wider px-2 py-0.5 rounded border font-medium ${cls}`}>
      {state}
    </span>
  );
}

// ── Toast ─────────────────────────────────────────────────────────────────────

function Toast({ msg }: { msg: string }) {
  return (
    <div className="fixed bottom-4 right-4 bg-mempool-bg-elev border border-mempool-border rounded px-4 py-2 text-xs text-mempool-text font-mono shadow-lg z-50">
      {msg}
    </div>
  );
}

// ── Row helper ────────────────────────────────────────────────────────────────

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex justify-between text-xs font-mono">
      <span className="text-mempool-text-dim">{label}</span>
      <span className="text-mempool-text">{value}</span>
    </div>
  );
}

// ── Main component ────────────────────────────────────────────────────────────

export function ChannelsPage() {
  const [tab, setTab] = useState<SubTab>("overview");
  const [prefillChannelId, setPrefillChannelId] = useState<string>("");

  const goToPayTab = (channelId: string) => {
    setPrefillChannelId(channelId);
    setTab("pay");
  };
  const goToCloseTab = (channelId: string) => {
    setPrefillChannelId(channelId);
    setTab("close");
  };

  return (
    <section className="bg-mempool-bg-elev rounded-lg p-3 sm:p-4 border border-mempool-border backdrop-blur-sm">
      <div className="flex items-center gap-2 sm:gap-3 mb-4">
        <Zap className="w-5 h-5 text-mempool-blue flex-shrink-0" />
        <h2 className="text-sm font-semibold text-mempool-text uppercase tracking-wider">
          Payment Channels
        </h2>
        <div className="flex-1 h-px bg-mempool-border" />
        <span className="text-[10px] sm:text-xs text-mempool-text-dim font-mono whitespace-nowrap">
          off-chain micropayments
        </span>
      </div>

      {/* Sub-tab bar */}
      <div className="flex gap-1 border-b border-mempool-border mb-4 overflow-x-auto scrollbar-none">
        {([
          { id: "overview", label: "Overview" },
          { id: "open",     label: "Open Channel" },
          { id: "pay",      label: "Pay" },
          { id: "close",    label: "Close" },
        ] as { id: SubTab; label: string }[]).map((t) => {
          const active = tab === t.id;
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={
                "relative flex-shrink-0 px-3 sm:px-4 py-2.5 text-xs font-medium uppercase tracking-wider transition-colors whitespace-nowrap " +
                (active
                  ? "text-mempool-blue"
                  : "text-mempool-text-dim hover:text-mempool-text")
              }
            >
              {t.label}
              {active && (
                <span className="absolute left-0 right-0 -bottom-px h-0.5 bg-mempool-blue" />
              )}
            </button>
          );
        })}
      </div>

      {tab === "overview" && (
        <OverviewTab onPayChannel={goToPayTab} onCloseChannel={goToCloseTab} />
      )}
      {tab === "open" && <OpenChannelTab />}
      {tab === "pay" && (
        <PayTab prefillChannelId={prefillChannelId} />
      )}
      {tab === "close" && (
        <CloseTab prefillChannelId={prefillChannelId} />
      )}
    </section>
  );
}

// ── Tab 1: Overview ───────────────────────────────────────────────────────────

function OverviewTab({
  onPayChannel,
  onCloseChannel,
}: {
  onPayChannel: (id: string) => void;
  onCloseChannel: (id: string) => void;
}) {
  const wallet = useWallet();
  const [data, setData] = useState<GetChannelsResp | null>(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [myOnly, setMyOnly] = useState(false);
  const [selected, setSelected] = useState<Channel | null>(null);

  // Derive user's pubkey for filtering
  const myPubkey = useMemo(() => {
    if (!wallet) return null;
    try {
      return getPubkeyFromPrivkey(wallet.privateKey);
    } catch {
      return null;
    }
  }, [wallet]);

  const refresh = useCallback(async () => {
    setLoading(true);
    setErr(null);
    try {
      const r = (await rpc.request_raw("getchannels", [])) as GetChannelsResp | null;
      setData(r ?? { summary: { open_count: 0, closing_count: 0, settled_count: 0, disputed_count: 0, total_locked_sat: 0 }, channels: [] });
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  // Initial load + WS-driven refresh on new blocks; 60 s fallback poll.
  useEffect(() => {
    void refresh();
    const unsub = wsSubscribe<WsNewBlockEvent>("new_block", () => { void refresh(); });
    const id = window.setInterval(() => { void refresh(); }, 60_000);
    return () => { window.clearInterval(id); unsub(); };
  }, [refresh]);

  const channels = useMemo(() => {
    const all = data?.channels ?? [];
    if (!myOnly || !myPubkey) return all;
    return all.filter((c) => c.party_a === myPubkey || c.party_b === myPubkey);
  }, [data, myOnly, myPubkey]);

  const summary = data?.summary;

  return (
    <div className="space-y-4">
      {/* Summary cards */}
      {summary && (
        <div className="grid grid-cols-3 gap-2 sm:gap-3">
          <div className="bg-mempool-bg border border-mempool-border rounded p-3">
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Total locked</div>
            <div className="text-base font-mono text-mempool-text mt-1">
              {toOMNI(summary.total_locked_sat)}
              <span className="text-xs text-mempool-text-dim ml-1">OMNI</span>
            </div>
          </div>
          <div className="bg-mempool-bg border border-mempool-border rounded p-3">
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Open channels</div>
            <div className="text-base font-mono text-green-400 mt-1">
              {intFmt.format(summary.open_count)}
            </div>
          </div>
          <div className="bg-mempool-bg border border-mempool-border rounded p-3">
            <div className="text-[10px] uppercase tracking-wider text-mempool-text-dim">Settled</div>
            <div className="text-base font-mono text-gray-400 mt-1">
              {intFmt.format(summary.settled_count)}
            </div>
          </div>
        </div>
      )}

      {/* Filter row */}
      <div className="flex flex-wrap items-center gap-3">
        {wallet && myPubkey && (
          <label className="flex items-center gap-2 text-xs text-mempool-text-dim cursor-pointer select-none">
            <input
              type="checkbox"
              checked={myOnly}
              onChange={(e) => setMyOnly(e.target.checked)}
              className="accent-mempool-blue"
            />
            Filter: My channels
          </label>
        )}
        <div className="flex-1" />
        {channels.length > 0 && (
          <button
            onClick={() => {
              const rows = [
                ["channel_id","party_a","party_b","balance_a_omni","balance_b_omni","capacity_omni","sequence_num","state"].join(","),
                ...channels.map((c) => [
                  `"${c.channel_id}"`,
                  `"${c.party_a}"`,
                  `"${c.party_b}"`,
                  toOMNI(c.balance_a),
                  toOMNI(c.balance_b),
                  toOMNI(c.capacity_sat),
                  c.sequence_num,
                  c.state,
                ].join(",")),
              ].join("\n");
              const blob = new Blob([rows], { type: "text/csv" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = "omnibus-channels.csv";
              a.click(); URL.revokeObjectURL(url);
            }}
            className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue"
          >
            ⬇ CSV
          </button>
        )}
        <button
          onClick={() => void refresh()}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-2 text-xs rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? "animate-spin" : ""}`} />
          Refresh
        </button>
      </div>

      {err && (
        <p className="text-xs text-mempool-orange font-mono">{err}</p>
      )}

      {!err && channels.length === 0 && !loading && (
        <p className="text-xs text-mempool-text-dim font-mono py-6 text-center">
          No channels found. Open the "Open Channel" tab to create one.
        </p>
      )}

      {channels.length > 0 && (
        <div className="overflow-x-auto -mx-3 sm:mx-0">
          <table className="w-full min-w-[600px] text-xs font-mono">
            <thead className="sticky top-0 bg-mempool-bg-elev">
              <tr className="text-left text-mempool-text-dim uppercase tracking-wider">
                <th className="py-2 px-2 font-medium">Channel ID</th>
                <th className="py-2 px-2 font-medium">Party A</th>
                <th className="py-2 px-2 font-medium">Party B</th>
                <th className="py-2 px-2 font-medium text-right">Bal A (OMNI)</th>
                <th className="py-2 px-2 font-medium text-right">Bal B (OMNI)</th>
                <th className="py-2 px-2 font-medium text-center">State</th>
                <th className="py-2 px-2 font-medium text-right">Seq#</th>
                <th className="py-2 px-2 font-medium" />
              </tr>
            </thead>
            <tbody>
              {channels.map((c) => {
                const isMyA = myPubkey === c.party_a;
                const isMyB = myPubkey === c.party_b;
                const isMine = isMyA || isMyB;
                return (
                  <tr
                    key={c.channel_id}
                    className={
                      "border-t border-mempool-border/40 cursor-pointer " +
                      (selected?.channel_id === c.channel_id
                        ? "bg-mempool-blue/5"
                        : "hover:bg-mempool-bg")
                    }
                    onClick={() => setSelected(selected?.channel_id === c.channel_id ? null : c)}
                  >
                    <td className="py-2 px-2">
                      <span className="text-mempool-blue" title={c.channel_id}>
                        {midTrunc(c.channel_id, 8, 4)}
                      </span>
                      {isMine && (
                        <span className="ml-1 text-[9px] text-mempool-blue opacity-70">(me)</span>
                      )}
                    </td>
                    <td className="py-2 px-2 text-mempool-text-dim" title={c.party_a}>
                      {shortPubkey(c.party_a)}
                      {isMyA && <span className="ml-1 text-mempool-blue opacity-70">★</span>}
                    </td>
                    <td className="py-2 px-2 text-mempool-text-dim" title={c.party_b}>
                      {shortPubkey(c.party_b)}
                      {isMyB && <span className="ml-1 text-mempool-blue opacity-70">★</span>}
                    </td>
                    <td className="py-2 px-2 text-right text-mempool-text">
                      {toOMNI(c.balance_a)}
                    </td>
                    <td className="py-2 px-2 text-right text-mempool-text">
                      {toOMNI(c.balance_b)}
                    </td>
                    <td className="py-2 px-2 text-center">
                      <StateBadge state={c.state} />
                    </td>
                    <td className="py-2 px-2 text-right text-mempool-text-dim">
                      {intFmt.format(c.sequence_num)}
                    </td>
                    <td className="py-2 px-2">
                      <button
                        onClick={(e) => {
                          e.stopPropagation();
                          setSelected(selected?.channel_id === c.channel_id ? null : c);
                        }}
                        className="px-2 py-1 text-[10px] rounded border border-mempool-border text-mempool-text-dim hover:text-mempool-blue hover:border-mempool-blue whitespace-nowrap"
                      >
                        Details
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Channel details panel */}
      {selected && (
        <ChannelDetailsPanel
          channel={selected}
          onPay={() => onPayChannel(selected.channel_id)}
          onClose={() => onCloseChannel(selected.channel_id)}
          onDismiss={() => setSelected(null)}
        />
      )}
    </div>
  );
}

// ── Channel Details Panel ─────────────────────────────────────────────────────

function ChannelDetailsPanel({
  channel: c,
  onPay,
  onClose,
  onDismiss,
}: {
  channel: Channel;
  onPay: () => void;
  onClose: () => void;
  onDismiss: () => void;
}) {
  const capacity = c.balance_a + c.balance_b;
  const fracA = capacity > 0 ? (c.balance_a / capacity) * 100 : 50;
  return (
    <div className="bg-mempool-bg border border-mempool-border rounded p-4 space-y-3">
      <div className="flex items-center justify-between">
        <span className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold">
          Channel Details
        </span>
        <button
          onClick={onDismiss}
          className="text-xs text-mempool-text-dim hover:text-mempool-text px-2"
        >
          ✕
        </button>
      </div>

      <div className="space-y-1.5">
        <Row
          label="Channel ID"
          value={
            <span className="flex items-center gap-1">
              <span className="truncate max-w-[200px]" title={c.channel_id}>{c.channel_id}</span>
              <CopyButton text={c.channel_id} />
            </span>
          }
        />
        <Row
          label="Party A pubkey"
          value={
            <span className="flex items-center gap-1">
              <span className="truncate max-w-[180px]" title={c.party_a}>{c.party_a}</span>
              <CopyButton text={c.party_a} />
            </span>
          }
        />
        <Row
          label="Party B pubkey"
          value={
            <span className="flex items-center gap-1">
              <span className="truncate max-w-[180px]" title={c.party_b}>{c.party_b}</span>
              <CopyButton text={c.party_b} />
            </span>
          }
        />
        <Row label="Capacity" value={`${toOMNI(capacity)} OMNI`} />
        <Row label="Balance A" value={`${toOMNI(c.balance_a)} OMNI`} />
        <Row label="Balance B" value={`${toOMNI(c.balance_b)} OMNI`} />
        <Row label="State" value={<StateBadge state={c.state} />} />
        <Row label="Sequence #" value={intFmt.format(c.sequence_num)} />
      </div>

      {/* Balance bar */}
      <div>
        <div className="flex justify-between text-[10px] text-mempool-text-dim font-mono mb-1">
          <span>A: {fracA.toFixed(1)}%</span>
          <span>B: {(100 - fracA).toFixed(1)}%</span>
        </div>
        <div className="h-2 rounded bg-mempool-border overflow-hidden">
          <div
            className="h-full bg-mempool-blue transition-all"
            style={{ width: `${fracA}%` }}
          />
        </div>
      </div>

      {c.state === "open" && (
        <div className="flex gap-2 pt-1">
          <button
            onClick={onPay}
            className="flex items-center gap-1.5 px-3 py-2 text-xs rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25"
          >
            <Zap className="w-3.5 h-3.5" />
            Pay
          </button>
          <button
            onClick={onClose}
            className="flex items-center gap-1.5 px-3 py-2 text-xs rounded bg-mempool-orange/10 text-mempool-orange border border-mempool-orange/40 hover:bg-mempool-orange/20"
          >
            <XCircle className="w-3.5 h-3.5" />
            Close Channel
          </button>
        </div>
      )}
    </div>
  );
}

// ── Tab 2: Open Channel ───────────────────────────────────────────────────────

function OpenChannelTab() {
  const wallet = useWallet();
  const [theirPubkey, setTheirPubkey] = useState("");
  const [myAmountStr, setMyAmountStr] = useState("");
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [result, setResult] = useState<OpenChannelResp | null>(null);

  const myPubkey = useMemo(() => {
    if (!wallet) return "";
    try { return getPubkeyFromPrivkey(wallet.privateKey); }
    catch { return ""; }
  }, [wallet]);

  const myAmountSat = toSAT(parseFloat(myAmountStr) || 0);
  const canSubmit = !!wallet && myAmountSat > 0 && theirPubkey.length === 66 && !busy;

  const doOpen = async () => {
    if (!wallet) { setToast("Connect wallet first"); return; }
    if (theirPubkey.length !== 66) { setToast("Counterparty pubkey must be 66 hex chars"); return; }
    setBusy(true);
    try {
      const r = (await rpc.request_raw("openchannel", [
        myPubkey,
        theirPubkey,
        myAmountSat,
        0,
      ])) as OpenChannelResp;
      setResult(r);
      setToast(`Channel opened — ID ${r.channel_id.slice(0, 12)}…`);
      setMyAmountStr("");
      setTheirPubkey("");
    } catch (e) {
      setToast(`Open channel failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
      window.setTimeout(() => setToast(null), 7000);
    }
  };

  return (
    <div className="space-y-4">
      {!wallet && (
        <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          Connect a wallet to open a channel. Your private key never leaves the browser.
        </p>
      )}

      {/* Explanation */}
      <div className="flex items-start gap-2 bg-mempool-bg border border-mempool-border/60 rounded px-3 py-3">
        <Info className="w-4 h-4 text-mempool-blue flex-shrink-0 mt-0.5" />
        <p className="text-xs text-mempool-text-dim leading-relaxed">
          A payment channel locks OMNI between two parties. Both can send instant payments
          without blockchain confirmations until the channel is closed. Opening a channel
          locks your OMNI — you can always close it to get the balance back.
        </p>
      </div>

      {/* Your pubkey (readonly) */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Your pubkey (Party A)
        </label>
        <div className="flex items-center gap-1">
          <input
            type="text"
            value={myPubkey}
            readOnly
            className="flex-1 bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text-dim focus:outline-none cursor-default"
          />
          {myPubkey && <CopyButton text={myPubkey} />}
        </div>
        {!wallet && (
          <p className="text-[11px] text-mempool-text-dim font-mono">
            — connect wallet to populate
          </p>
        )}
      </div>

      {/* Counterparty pubkey */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Counterparty pubkey (Party B) — 66-char hex
        </label>
        <input
          type="text"
          value={theirPubkey}
          onChange={(e) => setTheirPubkey(e.target.value.trim())}
          placeholder="02… (66 hex chars)"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          maxLength={66}
        />
        {theirPubkey.length > 0 && theirPubkey.length !== 66 && (
          <p className="text-[11px] text-mempool-orange font-mono">
            Must be exactly 66 chars ({theirPubkey.length}/66)
          </p>
        )}
      </div>

      {/* Your deposit */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Your initial deposit (OMNI)
        </label>
        <input
          type="number"
          min="0"
          step="0.000000001"
          value={myAmountStr}
          onChange={(e) => setMyAmountStr(e.target.value)}
          placeholder="0.00000000"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        {myAmountSat > 0 && (
          <p className="text-[11px] text-mempool-text-dim font-mono">
            = {intFmt.format(myAmountSat)} SAT
          </p>
        )}
      </div>

      {/* Counterparty deposit: fixed 0 */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Counterparty deposit (OMNI)
        </label>
        <input
          type="text"
          value="0 (counterparty contributes 0 initially)"
          readOnly
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text-dim focus:outline-none cursor-default"
        />
      </div>

      <button
        onClick={() => void doOpen()}
        disabled={!canSubmit}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Opening channel…" : "Open Channel"}
      </button>

      {/* Success result */}
      {result && (
        <div className="bg-green-500/5 border border-green-500/30 rounded p-3 space-y-1.5">
          <div className="flex items-center gap-2">
            <CheckCircle2 className="w-4 h-4 text-green-400 flex-shrink-0" />
            <span className="text-xs text-green-400 font-semibold uppercase tracking-wider">Channel opened</span>
          </div>
          <Row label="Channel ID" value={
            <span className="flex items-center gap-1">
              <span title={result.channel_id}>{midTrunc(result.channel_id, 8, 4)}</span>
              <CopyButton text={result.channel_id} />
            </span>
          } />
          <Row label="Balance A" value={`${toOMNI(result.balance_a)} OMNI`} />
          <Row label="Balance B" value={`${toOMNI(result.balance_b)} OMNI`} />
          <Row label="Total locked" value={`${toOMNI(result.total_locked)} OMNI`} />
          <Row label="State" value={<StateBadge state={result.state} />} />
        </div>
      )}

      {toast && <Toast msg={toast} />}
    </div>
  );
}

// ── Tab 3: Pay ────────────────────────────────────────────────────────────────

function PayTab({ prefillChannelId }: { prefillChannelId: string }) {
  const wallet = useWallet();
  const [channelId, setChannelId] = useState(prefillChannelId);
  const [direction, setDirection] = useState<"a_to_b" | "b_to_a">("a_to_b");
  const [amountStr, setAmountStr] = useState("");
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [result, setResult] = useState<ChannelPayResp | null>(null);

  // Sync prefill when navigating from details panel
  useEffect(() => {
    if (prefillChannelId) setChannelId(prefillChannelId);
  }, [prefillChannelId]);

  const amountSat = toSAT(parseFloat(amountStr) || 0);
  const canSubmit = !!wallet && channelId.length === 64 && amountSat > 0 && !busy;

  const doPay = async () => {
    if (!wallet) { setToast("Connect wallet first"); return; }
    if (channelId.length !== 64) { setToast("Channel ID must be 64 hex chars"); return; }
    setBusy(true);
    try {
      // Fetch current sequence from chain first so we can compute next
      let nextSeq = 1;
      try {
        const ch = (await rpc.request_raw("getchannels", [])) as GetChannelsResp | null;
        const found = ch?.channels.find((c) => c.channel_id === channelId);
        if (found) nextSeq = found.sequence_num + 1;
      } catch { /* use 1 as fallback */ }

      const sigA = signChannelPay({
        privateKeyHex: wallet.privateKey,
        channelId,
        direction,
        amount: amountSat,
        nextSeq,
      });
      // Demo/testnet: both signatures use the same key (party A)
      const sigB = sigA;

      const r = (await rpc.request_raw("channelpay", [
        channelId,
        direction,
        amountSat,
        sigA,
        sigB,
      ])) as ChannelPayResp;
      setResult(r);
      setToast(`Payment sent — seq #${r.sequence_num}`);
      setAmountStr("");
    } catch (e) {
      setToast(`Payment failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
      window.setTimeout(() => setToast(null), 7000);
    }
  };

  return (
    <div className="space-y-4">
      {!wallet && (
        <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          Connect a wallet to send channel payments.
        </p>
      )}

      {/* Dual-sig note */}
      <div className="flex items-start gap-2 bg-mempool-bg border border-mempool-border/60 rounded px-3 py-3">
        <AlertTriangle className="w-4 h-4 text-yellow-400 flex-shrink-0 mt-0.5" />
        <p className="text-xs text-mempool-text-dim leading-relaxed">
          <span className="text-yellow-400 font-semibold">Dual signatures required.</span>{" "}
          In production, the counterparty signs the new state via their own wallet.
          For testnet/demo, both signatures use Party A&apos;s key — this is only safe
          in a controlled testing environment.
        </p>
      </div>

      {/* Channel ID */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Channel ID (64-char hex)
        </label>
        <input
          type="text"
          value={channelId}
          onChange={(e) => setChannelId(e.target.value.trim())}
          placeholder="64-char hex channel ID"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          maxLength={64}
        />
        {channelId.length > 0 && channelId.length !== 64 && (
          <p className="text-[11px] text-mempool-orange font-mono">
            Must be exactly 64 chars ({channelId.length}/64)
          </p>
        )}
      </div>

      {/* Direction */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Direction
        </label>
        <div className="grid grid-cols-2 gap-2">
          <button
            type="button"
            onClick={() => setDirection("a_to_b")}
            className={
              "flex items-center justify-center gap-1.5 px-3 py-2.5 text-xs rounded border font-mono transition-colors " +
              (direction === "a_to_b"
                ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
            }
          >
            <ArrowRight className="w-3.5 h-3.5" />
            I send (A → B)
          </button>
          <button
            type="button"
            onClick={() => setDirection("b_to_a")}
            className={
              "flex items-center justify-center gap-1.5 px-3 py-2.5 text-xs rounded border font-mono transition-colors " +
              (direction === "b_to_a"
                ? "bg-mempool-blue/15 text-mempool-blue border-mempool-blue"
                : "bg-mempool-bg text-mempool-text-dim border-mempool-border hover:text-mempool-text")
            }
          >
            <ArrowLeft className="w-3.5 h-3.5" />
            I receive (B → A)
          </button>
        </div>
        <p className="text-[11px] text-mempool-text-dim font-mono">
          direction: <span className="text-mempool-text">{direction}</span>
        </p>
      </div>

      {/* Amount */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Amount (OMNI)
        </label>
        <input
          type="number"
          min="0"
          step="0.000000001"
          value={amountStr}
          onChange={(e) => setAmountStr(e.target.value)}
          placeholder="0.00000000"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-sm font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
        />
        {amountSat > 0 && (
          <p className="text-[11px] text-mempool-text-dim font-mono">
            = {intFmt.format(amountSat)} SAT
          </p>
        )}
      </div>

      <button
        onClick={() => void doPay()}
        disabled={!canSubmit}
        className="w-full px-4 py-2.5 rounded bg-mempool-blue/15 text-mempool-blue border border-mempool-blue/40 hover:bg-mempool-blue/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Signing & sending…" : "Send Payment"}
      </button>

      {/* Result */}
      {result && (
        <div className="bg-green-500/5 border border-green-500/30 rounded p-3 space-y-1.5">
          <div className="flex items-center gap-2">
            <CheckCircle2 className="w-4 h-4 text-green-400 flex-shrink-0" />
            <span className="text-xs text-green-400 font-semibold uppercase tracking-wider">Payment sent</span>
          </div>
          <Row label="Sequence #" value={intFmt.format(result.sequence_num)} />
          <Row label="New balance A" value={`${toOMNI(result.balance_a)} OMNI`} />
          <Row label="New balance B" value={`${toOMNI(result.balance_b)} OMNI`} />
        </div>
      )}

      {toast && <Toast msg={toast} />}
    </div>
  );
}

// ── Tab 4: Close ──────────────────────────────────────────────────────────────

function CloseTab({ prefillChannelId }: { prefillChannelId: string }) {
  const wallet = useWallet();
  const [channelId, setChannelId] = useState(prefillChannelId);
  const [channelInfo, setChannelInfo] = useState<Channel | null>(null);
  const [loadingInfo, setLoadingInfo] = useState(false);
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [result, setResult] = useState<CloseChannelResp | null>(null);

  // Sync prefill from details panel
  useEffect(() => {
    if (prefillChannelId) setChannelId(prefillChannelId);
  }, [prefillChannelId]);

  // Auto-load channel details when a valid ID is entered
  useEffect(() => {
    if (channelId.length !== 64) { setChannelInfo(null); return; }
    let cancelled = false;
    const load = async () => {
      setLoadingInfo(true);
      try {
        const r = (await rpc.request_raw("getchannels", [])) as GetChannelsResp | null;
        if (!cancelled) {
          const found = r?.channels.find((c) => c.channel_id === channelId) ?? null;
          setChannelInfo(found);
        }
      } catch { if (!cancelled) setChannelInfo(null); }
      finally { if (!cancelled) setLoadingInfo(false); }
    };
    void load();
    return () => { cancelled = true; };
  }, [channelId]);

  const canSubmit = !!wallet && channelId.length === 64 && !busy;

  const doClose = async () => {
    if (!wallet) { setToast("Connect wallet first"); return; }
    if (channelId.length !== 64) { setToast("Channel ID must be 64 hex chars"); return; }
    setBusy(true);
    try {
      const sigA = signChannelClose({ privateKeyHex: wallet.privateKey, channelId });
      // Demo/testnet: both signatures use the same key
      const sigB = sigA;

      const r = (await rpc.request_raw("closechannel", [
        channelId,
        sigA,
        sigB,
      ])) as CloseChannelResp;
      setResult(r);
      setToast(`Channel closed — final balances settled on-chain`);
      setChannelInfo(null);
    } catch (e) {
      setToast(`Close failed: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
      window.setTimeout(() => setToast(null), 7000);
    }
  };

  return (
    <div className="space-y-4">
      {!wallet && (
        <p className="text-xs text-mempool-orange font-mono bg-mempool-orange/10 border border-mempool-orange/30 rounded px-3 py-2">
          Connect a wallet to close a channel.
        </p>
      )}

      {/* Explanation */}
      <div className="flex items-start gap-2 bg-mempool-bg border border-mempool-border/60 rounded px-3 py-3">
        <Info className="w-4 h-4 text-mempool-blue flex-shrink-0 mt-0.5" />
        <p className="text-xs text-mempool-text-dim leading-relaxed">
          Closing broadcasts the final channel state to the blockchain. Both parties receive
          their OMNI back according to the last signed balance update. For testnet/demo,
          both close signatures use Party A&apos;s key.
        </p>
      </div>

      {/* Channel ID */}
      <div className="space-y-1.5">
        <label className="text-[10px] uppercase tracking-wider text-mempool-text-dim">
          Channel ID (64-char hex)
        </label>
        <input
          type="text"
          value={channelId}
          onChange={(e) => setChannelId(e.target.value.trim())}
          placeholder="64-char hex channel ID"
          className="w-full bg-mempool-bg border border-mempool-border rounded px-3 py-2 text-xs font-mono text-mempool-text placeholder:text-mempool-text-dim focus:outline-none focus:border-mempool-blue"
          maxLength={64}
        />
        {channelId.length > 0 && channelId.length !== 64 && (
          <p className="text-[11px] text-mempool-orange font-mono">
            Must be exactly 64 chars ({channelId.length}/64)
          </p>
        )}
      </div>

      {/* Channel info */}
      {loadingInfo && (
        <div className="flex items-center gap-2 text-xs text-mempool-text-dim font-mono">
          <Clock className="w-3.5 h-3.5 animate-spin" />
          Loading channel…
        </div>
      )}
      {channelInfo && (
        <div className="bg-mempool-bg border border-mempool-border rounded p-3 space-y-1.5">
          <p className="text-[10px] uppercase tracking-wider text-mempool-text-dim font-semibold mb-2">
            Current channel state
          </p>
          <Row label="State" value={<StateBadge state={channelInfo.state} />} />
          <Row label="Balance A" value={`${toOMNI(channelInfo.balance_a)} OMNI`} />
          <Row label="Balance B" value={`${toOMNI(channelInfo.balance_b)} OMNI`} />
          <Row label="Sequence #" value={intFmt.format(channelInfo.sequence_num)} />
          {channelInfo.state !== "open" && (
            <p className="text-xs text-yellow-400 font-mono pt-1">
              Channel state is "{channelInfo.state}" — already closed or in dispute.
            </p>
          )}
        </div>
      )}
      {channelId.length === 64 && !loadingInfo && !channelInfo && (
        <p className="text-xs text-mempool-text-dim font-mono">
          Channel not found on chain (or RPC unavailable).
        </p>
      )}

      <button
        onClick={() => void doClose()}
        disabled={!canSubmit || channelInfo?.state !== "open"}
        className="w-full px-4 py-2.5 rounded bg-mempool-orange/15 text-mempool-orange border border-mempool-orange/40 hover:bg-mempool-orange/25 disabled:opacity-40 disabled:cursor-not-allowed text-sm font-medium uppercase tracking-wider"
      >
        {busy ? "Signing & broadcasting…" : "Close Channel"}
      </button>

      {/* Final result */}
      {result && (
        <div className="bg-green-500/5 border border-green-500/30 rounded p-3 space-y-1.5">
          <div className="flex items-center gap-2">
            <CheckCircle2 className="w-4 h-4 text-green-400 flex-shrink-0" />
            <span className="text-xs text-green-400 font-semibold uppercase tracking-wider">Channel settled</span>
          </div>
          <Row label="State" value={<StateBadge state={result.state} />} />
          <Row label="Final balance A" value={`${toOMNI(result.final_balance_a)} OMNI`} />
          <Row label="Final balance B" value={`${toOMNI(result.final_balance_b)} OMNI`} />
          {result.tx_hash_a && (
            <Row label="TX hash A" value={
              <span title={result.tx_hash_a}>{midTrunc(result.tx_hash_a, 8, 4)}</span>
            } />
          )}
          {result.tx_hash_b && (
            <Row label="TX hash B" value={
              <span title={result.tx_hash_b}>{midTrunc(result.tx_hash_b, 8, 4)}</span>
            } />
          )}
        </div>
      )}

      {toast && <Toast msg={toast} />}
    </div>
  );
}

export default ChannelsPage;
